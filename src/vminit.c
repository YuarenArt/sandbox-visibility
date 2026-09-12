/*
 * PID 1 of the VM guest: mounts the pseudo filesystems and the network, runs the
 * generator, powers the machine off.
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
	 * The working directory must live on the storage this row measures.
	 * Falling back to the image would silently turn the shared-directory row
	 * into a second block-root run.
	 */
	workdir = WORK;
	if (cmdline_val("svp_share=", share, sizeof(share)) &&
	    strcmp(share, "yes") == 0) {
		mkdir(SHARE, 0700);
		if (mount("svpshare", SHARE, "virtiofs", 0, NULL) != 0) {
			printf("### SHARE-MOUNT-FAILED errno=%d\n", errno);
			printf("### GUEST-FAIL\n");
			sync();
			reboot(RB_POWER_OFF);
			for (;;)
				pause();
		}
		workdir = SHARE;
		printf("### SHARE-MOUNTED %s\n", SHARE);
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
	 * Do not dump truth.txt to the console: the VMM writes the console inside
	 * the observation window, and a chunk starting at a marker would count as
	 * a guest write. The host reads the file from the image after shutdown.
	 */
	printf("### GUEST-DONE\n");

	sync();
	reboot(RB_POWER_OFF);
	for (;;)
		pause();
	return 0;
}
