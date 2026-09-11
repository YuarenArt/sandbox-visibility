/*
 * Заведомо известный ответ для каждой пробы наблюдателя.
 *
 * Вызовы делаются напрямую через syscall(), а не через libc: иначе неизвестно,
 * какой именно вызов ушёл в ядро. Ровно на этом стенд спотыкался трижды:
 * проба стояла на unlinkat, а libc звала unlink; пробы на open не было, а
 * firecracker звал именно его; проба на write была, а virtiofsd писал pwritev.
 *
 * Каждый вызов помечен своим токеном, чтобы проверка была поимённой: «проба
 * жива» и «проба ловит именно этот вызов» это разные утверждения.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

static const char *runid;

static void mk(char *out, size_t n, const char *what)
{
	snprintf(out, n, "SVP-%s-%s", runid, what);
}

int main(int argc, char **argv)
{
	char path[256], buf[256];
	struct iovec iov;
	struct sockaddr_in sa;
	int fd, s, port;
	pid_t pid;

	runid = argc > 1 ? argv[1] : "probecheck";
	port = argc > 2 ? atoi(argv[2]) : 27000;

	/* open, устаревший вызов номер 2 */
	mk(path, sizeof(path), "pc-open.dat");
	fd = syscall(SYS_open, path, O_RDWR | O_CREAT, 0600);
	if (fd >= 0)
		close(fd);

	/* openat */
	mk(path, sizeof(path), "pc-openat.dat");
	fd = syscall(SYS_openat, AT_FDCWD, path, O_RDWR | O_CREAT, 0600);

	/* write */
	mk(buf, sizeof(buf), "pc-write");
	strcat(buf, "\n");
	if (fd >= 0)
		syscall(SYS_write, fd, buf, strlen(buf) + 1);

	/* pwritev */
	mk(buf, sizeof(buf), "pc-pwritev");
	strcat(buf, "\n");
	iov.iov_base = buf;
	iov.iov_len = strlen(buf) + 1;
	if (fd >= 0)
		syscall(SYS_pwritev, fd, &iov, 1, 0);

	/* pwrite64 */
	mk(buf, sizeof(buf), "pc-pwrite64");
	strcat(buf, "\n");
	if (fd >= 0)
		syscall(SYS_pwrite64, fd, buf, strlen(buf) + 1, 0);
	if (fd >= 0)
		close(fd);

	/* unlink, устаревший */
	mk(path, sizeof(path), "pc-open.dat");
	syscall(SYS_unlink, path);

	/* unlinkat */
	mk(path, sizeof(path), "pc-openat.dat");
	syscall(SYS_unlinkat, AT_FDCWD, path, 0);

	/* connect */
	s = socket(AF_INET, SOCK_STREAM, 0);
	if (s >= 0) {
		memset(&sa, 0, sizeof(sa));
		sa.sin_family = AF_INET;
		sa.sin_port = htons(port);
		inet_pton(AF_INET, "127.0.0.1", &sa.sin_addr);
		syscall(SYS_connect, s, &sa, sizeof(sa));
		close(s);
	}

	/* execve */
	mk(path, sizeof(path), "pc-exec.bin");
	if (argc > 3) {
		char cmd[600];
		snprintf(cmd, sizeof(cmd), "%s", argv[3]);
		fd = open(cmd, O_RDONLY);
		if (fd >= 0) {
			int out = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0755);
			char b[65536];
			ssize_t n;
			while (out >= 0 && (n = read(fd, b, sizeof(b))) > 0) {
				if (write(out, b, n) != n)
					break;
			}
			close(fd);
			if (out >= 0)
				close(out);
			pid = fork();
			if (pid == 0) {
				execl(path, path, (char *)NULL);
				_exit(127);
			}
			if (pid > 0)
				waitpid(pid, NULL, 0);
		}
	}

	printf("PROBECHECK-DONE\n");
	return 0;
}
