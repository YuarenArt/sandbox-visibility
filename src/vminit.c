/*
 * PID 1 гостя виртуальной машины. Поднимает псевдо-ФС и сеть, запускает
 * генератор, печатает истину на последовательную консоль и выключает машину.
 *
 * Истина печатается на консоль намеренно: корень гостя может быть блочным
 * образом, который хост читает только посмертно, а сравнивать надо с тем, что
 * гость действительно сделал, а не с тем, что от него осталось.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define WORK "/work"
#define SHARE "/share"

static int cmdline_val(const char *key, char *out, size_t len)
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

static void iface_up(const char *name, const char *addr, const char *mask)
{
	struct ifreq ifr;
	struct sockaddr_in *sin;
	int s;

	s = socket(AF_INET, SOCK_DGRAM, 0);
	if (s < 0)
		return;

	memset(&ifr, 0, sizeof(ifr));
	snprintf(ifr.ifr_name, IFNAMSIZ, "%s", name);

	if (addr) {
		sin = (struct sockaddr_in *)&ifr.ifr_addr;
		sin->sin_family = AF_INET;
		inet_pton(AF_INET, addr, &sin->sin_addr);
		ioctl(s, SIOCSIFADDR, &ifr);

		if (mask) {
			memset(&ifr, 0, sizeof(ifr));
			snprintf(ifr.ifr_name, IFNAMSIZ, "%s", name);
			sin = (struct sockaddr_in *)&ifr.ifr_netmask;
			sin->sin_family = AF_INET;
			inet_pton(AF_INET, mask, &sin->sin_addr);
			ioctl(s, SIOCSIFNETMASK, &ifr);
		}
	}

	memset(&ifr, 0, sizeof(ifr));
	snprintf(ifr.ifr_name, IFNAMSIZ, "%s", name);
	ioctl(s, SIOCGIFFLAGS, &ifr);
	ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
	ioctl(s, SIOCSIFFLAGS, &ifr);
	close(s);
}

int main(void)
{
	char port[32], addr[64], gaddr[64], share[32];
	const char *workdir;
	pid_t pid;
	int status;

	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	setvbuf(stdout, NULL, _IONBF, 0);

	iface_up("lo", NULL, NULL);
	if (cmdline_val("svp_guestaddr=", gaddr, sizeof(gaddr)))
		iface_up("eth0", gaddr, "255.255.255.0");
	else
		iface_up("eth0", NULL, NULL);

	if (!cmdline_val("svp_port=", port, sizeof(port)))
		snprintf(port, sizeof(port), "27000");
	if (!cmdline_val("svp_addr=", addr, sizeof(addr)))
		snprintf(addr, sizeof(addr), "127.0.0.1");

	mkdir(WORK, 0700);

	/*
	 * Рабочий каталог обязан лежать на том хранилище, которое эта строка
	 * измеряет. Без монтирования общего каталога строка virtiofs повторяла
	 * бы опыт с блочным корнем при простаивающем virtiofsd, и вывод про
	 * общий каталог делался бы без единой операции через общий каталог.
	 */
	workdir = WORK;
	if (cmdline_val("svp_share=", share, sizeof(share)) &&
	    strcmp(share, "yes") == 0) {
		mkdir(SHARE, 0700);
		if (mount("svpshare", SHARE, "virtiofs", 0, NULL) == 0) {
			workdir = SHARE;
			printf("### SHARE-MOUNTED %s\n", SHARE);
		} else {
			printf("### SHARE-MOUNT-FAILED errno=%d\n", errno);
		}
	}

	printf("### GUEST-START workdir=%s\n", workdir);
	pid = fork();
	if (pid == 0) {
		if (chdir(workdir) != 0)
			_exit(126);
		execl("/bin/gen", "gen", "truth.txt", "/bin/svp-target", port,
		      addr, (char *)NULL);
		_exit(127);
	}
	waitpid(pid, &status, 0);

	/*
	 * Истина намеренно НЕ выливается на консоль. Монитор виртуальной машины
	 * пишет консоль на хост уже внутри окна наблюдения, и кусок такой записи
	 * может начаться прямо с маркера, попав в колонку write. Это смешало бы
	 * канал «собственная запись гостя» с каналом «вывод консоли», которые
	 * стенд обязан разводить. Файл остаётся в образе, хост читает его после
	 * выключения машины через debugfs, вне окна наблюдения.
	 */
	printf("### GUEST-DONE\n");

	sync();
	reboot(RB_POWER_OFF);
	for (;;)
		pause();
	return 0;
}
