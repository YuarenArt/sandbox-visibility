/*
 * Генератор действий нагрузки. Работает внутри песочницы, в том числе как PID 1
 * в виртуальной машине, где идентификатор прогона берётся из /proc/cmdline.
 *
 * Каждая операция получает собственный токен, который попадает в аргумент
 * системного вызова. Токен не может возникнуть сам, поэтому по нему однозначно
 * решается, дожила операция до наблюдателя или нет. Полнота считается по типам
 * операций отдельно: общего числа «маркеров» здесь нет намеренно, в первом
 * заходе именно оно и оказалось суммой трёх колонок из пяти.
 *
 * В истину пишется исход с errno, а не факт попытки: операция, не прошедшая в
 * госте, не может быть увидена на хосте, и включать её в знаменатель нельзя.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define REPS 10
#define TOKLEN 96
#define CONNECT_TIMEOUT_MS 1000

static FILE *truth;
static char runid[64];

struct counters {
	int attempted;
	int succeeded;
};

static struct counters c_open, c_write, c_read, c_connect, c_exec, c_unlink;

static long long now_ns(clockid_t clk)
{
	struct timespec ts;

	clock_gettime(clk, &ts);
	return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static void record(const char *op, const char *tok, int rc, int err)
{
	fprintf(truth, "op=%s tok=%s rc=%d errno=%d real=%lld mono=%lld\n", op,
		tok, rc, err, now_ns(CLOCK_REALTIME), now_ns(CLOCK_MONOTONIC));
	fflush(truth);
}

static void token(char *out, const char *op, int i)
{
	snprintf(out, TOKLEN, "SVP-%s-%s-%03d", runid, op, i);
}

/* В виртуальной машине генератор стартует как PID 1 и получает параметры только
   из командной строки ядра. */
static int from_cmdline(const char *key, char *out, size_t len)
{
	char buf[4096], *p;
	int fd, n;
	size_t k = 0;

	out[0] = '\0';
	fd = open("/proc/cmdline", O_RDONLY);
	if (fd < 0)
		return 0;
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return 0;
	buf[n] = '\0';
	p = strstr(buf, key);
	if (!p)
		return 0;
	p += strlen(key);
	while (p[k] && p[k] != ' ' && p[k] != '\n' && k < len - 1) {
		out[k] = p[k];
		k++;
	}
	out[k] = '\0';
	return k > 0;
}

static void read_runid(void)
{
	const char *env = getenv("SVP_RUNID");

	if (env && *env) {
		snprintf(runid, sizeof(runid), "%s", env);
		return;
	}
	if (from_cmdline("svp_runid=", runid, sizeof(runid)))
		return;
	snprintf(runid, sizeof(runid), "NORUNID");
}

/*
 * В истину пишется тот токен, который реально стоит в аргументе вызова, а не
 * токен с именем операции. Иначе искать в трейсе будет нечего: open и unlink
 * работают с одним и тем же путём, и если для unlink записать отдельный токен,
 * его в аргументах не будет никогда, а колонка покажет уверенный ноль во всех
 * средах, включая положительный контроль.
 *
 * Различает операции сам наблюдатель по имени системного вызова, для этого
 * отдельный токен на операцию не нужен.
 */
static void do_files(void)
{
	char ftok[TOKLEN], wtok[TOKLEN], path[256], buf[256];
	int i, fd, rc;

	for (i = 0; i < REPS; i++) {
		token(ftok, "file", i);
		snprintf(path, sizeof(path), "%s.dat", ftok);

		c_open.attempted++;
		fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0600);
		record("open", ftok, fd, fd < 0 ? errno : 0);
		if (fd < 0)
			continue;
		c_open.succeeded++;

		token(wtok, "write", i);
		snprintf(buf, sizeof(buf), "%s\n", wtok);
		c_write.attempted++;
		/* Завершающий ноль пишется намеренно: наблюдатель читает буфер
		   строкой и без него дочитывает до чужих данных, засоряя трейс
		   двоичным мусором. После этого grep считает файл двоичным и
		   молча подавляет вывод, то есть анализатор выдаёт пустую
		   таблицу, не сообщая причины. */
		rc = write(fd, buf, strlen(buf) + 1);
		record("write", wtok, rc, rc < 0 ? errno : 0);
		if (rc > 0)
			c_write.succeeded++;

		/* Аргумент read это дескриптор, а не путь, поэтому по содержимому
		   аргументов эта операция ненаблюдаема в принципе. Записывается,
		   чтобы в таблице стояло «не инструментировано», а не ноль. */
		lseek(fd, 0, SEEK_SET);
		c_read.attempted++;
		rc = read(fd, buf, sizeof(buf));
		record("read", "NOT-INSTRUMENTED", rc, rc < 0 ? errno : 0);
		if (rc > 0)
			c_read.succeeded++;

		close(fd);

		c_unlink.attempted++;
		rc = unlink(path);
		record("unlink", ftok, rc, rc < 0 ? errno : 0);
		if (rc == 0)
			c_unlink.succeeded++;
	}
}

/* Недостижимый адрес иначе вешает генератор на минуты повторов SYN, и одна
   неверно настроенная среда парализует весь стенд. */
static int connect_timeout(int s, struct sockaddr_in *sa)
{
	struct pollfd pfd;
	int flags, err = 0, rc;
	socklen_t elen = sizeof(err);

	flags = fcntl(s, F_GETFL, 0);
	fcntl(s, F_SETFL, flags | O_NONBLOCK);

	rc = connect(s, (struct sockaddr *)sa, sizeof(*sa));
	if (rc == 0)
		goto done;
	if (errno != EINPROGRESS)
		return -1;

	pfd.fd = s;
	pfd.events = POLLOUT;
	rc = poll(&pfd, 1, CONNECT_TIMEOUT_MS);
	if (rc == 0) {
		errno = ETIMEDOUT;
		return -1;
	}
	if (rc < 0)
		return -1;

	if (getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &elen) < 0)
		return -1;
	if (err) {
		errno = err;
		return -1;
	}
done:
	fcntl(s, F_SETFL, flags);
	return 0;
}

/*
 * Порт выводится из номера повторения, чтобы его можно было сопоставить с
 * конкретной операцией: аргумент connect не содержит текстового токена.
 *
 * Адрес назначения задаётся снаружи. В виртуальной машине 127.0.0.1 это
 * loopback самого гостя, и такое обращение до хоста не доходит вовсе, то есть
 * среды с зашитым loopback были бы несравнимы по построению.
 */
static void do_connect(int base_port, const char *addr)
{
	char tok[TOKLEN];
	struct sockaddr_in sa;
	int i, s, rc;

	for (i = 0; i < REPS; i++) {
		token(tok, "connect", i);
		c_connect.attempted++;

		s = socket(AF_INET, SOCK_STREAM, 0);
		if (s < 0) {
			record("connect", tok, -1, errno);
			continue;
		}
		memset(&sa, 0, sizeof(sa));
		sa.sin_family = AF_INET;
		sa.sin_port = htons(base_port + i);
		if (inet_pton(AF_INET, addr, &sa.sin_addr) != 1)
			sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

		rc = connect_timeout(s, &sa);
		record("connect", tok, rc, rc < 0 ? errno : 0);
		if (rc == 0)
			c_connect.succeeded++;
		close(s);
	}
}

static int copy_file(const char *src, const char *dst)
{
	char buf[65536];
	ssize_t n;
	int in, out, rc = 0;

	in = open(src, O_RDONLY);
	if (in < 0)
		return -1;
	out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0755);
	if (out < 0) {
		close(in);
		return -1;
	}
	while ((n = read(in, buf, sizeof(buf))) > 0) {
		if (write(out, buf, n) != n) {
			rc = -1;
			break;
		}
	}
	close(in);
	close(out);
	return rc;
}

static void do_exec(const char *target)
{
	char tok[TOKLEN], path[256];
	int i, status;
	pid_t pid;

	for (i = 0; i < REPS; i++) {
		token(tok, "exec", i);
		snprintf(path, sizeof(path), "%s.bin", tok);
		c_exec.attempted++;

		if (copy_file(target, path) != 0) {
			record("exec", tok, -1, errno);
			continue;
		}

		pid = fork();
		if (pid == 0) {
			execl(path, path, (char *)NULL);
			_exit(127);
		}
		if (pid < 0) {
			record("exec", tok, -1, errno);
			continue;
		}
		waitpid(pid, &status, 0);
		if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
			record("exec", tok, 0, 0);
			c_exec.succeeded++;
		} else {
			record("exec", tok, -1, ECHILD);
		}
		/* Убирать за собой здесь нельзя: это дало бы ещё десять событий
		   unlink с маркерами, не входящих ни в один знаменатель, и
		   колонка unlink считала бы вдвое больше сделанного. Рабочий
		   каталог всё равно пересоздаётся перед каждым повтором. */
	}
}

static void report(const char *name, struct counters *c)
{
	/* Когда истина идёт в стандартный поток, это один и тот же поток:
	   двойная печать дала бы по два знаменателя на операцию, и проверка
	   полноты сочла бы истину частичной. */
	if (truth != stdout)
		printf("denom %s attempted=%d succeeded=%d\n", name,
		       c->attempted, c->succeeded);
	fprintf(truth, "denom %s attempted=%d succeeded=%d\n", name,
		c->attempted, c->succeeded);
}

int main(int argc, char **argv)
{
	const char *truth_path = argc > 1 ? argv[1] : "truth.txt";
	const char *exec_target = argc > 2 ? argv[2] : "/bin/svp-target";
	int base_port = argc > 3 ? atoi(argv[3]) : 27000;
	const char *addr = argc > 4 ? argv[4] : getenv("SVP_ADDR");
	char receipt[256], addrbuf[64];
	int fd;

	read_runid();

	if (!addr || !*addr) {
		if (from_cmdline("svp_addr=", addrbuf, sizeof(addrbuf)))
			addr = addrbuf;
		else
			addr = "127.0.0.1";
	}

	/*
	 * На /dev/stdout нельзя открывать второй поток: получаются два FILE* с
	 * разными буферами на одном дескрипторе, записи перемешиваются, и часть
	 * строк истины теряется. Опасно это тем, что знаменатель молча
	 * уменьшается, а полнота выглядит лучше настоящей.
	 */
	if (strcmp(truth_path, "-") == 0 ||
	    strcmp(truth_path, "/dev/stdout") == 0) {
		truth = stdout;
	} else {
		truth = fopen(truth_path, "w");
		if (!truth)
			truth = stdout;
	}
	setvbuf(stdout, NULL, _IONBF, 0);
	if (truth != stdout)
		setvbuf(truth, NULL, _IOLBF, 0);

	/* Когда истина идёт в стандартный вывод, это один и тот же поток, и
	   заголовок печатать дважды нельзя. */
	if (truth != stdout)
		printf("runid %s\n", runid);
	fprintf(truth, "runid %s\n", runid);
	fprintf(truth, "connect addr=%s base_port=%d\n", addr, base_port);
	fprintf(truth, "start real=%lld mono=%lld\n", now_ns(CLOCK_REALTIME),
		now_ns(CLOCK_MONOTONIC));

	/*
	 * Пустой режим для отрицательного контроля. Среда, путь запуска и
	 * идентификатор прогона те же, действий ноль. Прежний контроль был
	 * sleep на хосте: песочница не запускалась, идентификатор не
	 * передавался, и провалиться такая строка не могла в принципе, то есть
	 * не проверяла ничего.
	 */
	if (getenv("SVP_NOOP") == NULL) {
		do_files();
		do_connect(base_port, addr);
		do_exec(exec_target);
	} else {
		if (truth != stdout)
			printf("noop mode\n");
		fprintf(truth, "noop mode\n");
	}

	/* Расписка намеренно не удаляется: она читается с хоста прямо из образа
	   и отличает «хост не увидел» от «гость не сделал». */
	/* В пустом режиме расписки быть не должно: отрицательный контроль давал
	   три маркера вместо нуля именно на её открытии. */
	if (getenv("SVP_NOOP") != NULL)
		goto done;

	snprintf(receipt, sizeof(receipt), "SVP-%s-receipt", runid);
	fd = open(receipt, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd >= 0) {
		/* Содержимое намеренно начинается не с маркера: наблюдатель
		   отбирает записи по префиксу, и расписка иначе попала бы в
		   колонку write лишним одиннадцатым событием. Маркер несёт имя
		   файла, этого достаточно для пробы на открытие. */
		if (write(fd, "receipt ", 8) < 0 ||
		    write(fd, receipt, strlen(receipt)) < 0 ||
		    write(fd, "\n", 1) < 0)
			perror("receipt");
		close(fd);
	}

done:
	report("open", &c_open);
	report("write", &c_write);
	report("read", &c_read);
	report("connect", &c_connect);
	report("exec", &c_exec);
	report("unlink", &c_unlink);

	fprintf(truth, "end real=%lld mono=%lld\n", now_ns(CLOCK_REALTIME),
		now_ns(CLOCK_MONOTONIC));
	if (truth != stdout)
		fclose(truth);

	printf("SVP-DONE\n");
	return 0;
}
