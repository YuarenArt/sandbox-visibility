/*
 * Known-answer test for every probe in trace.bt. Syscalls are issued through
 * syscall() rather than libc so the kernel entry point is unambiguous: libc is
 * free to route unlink() to unlinkat(), and a probe sitting on the wrong entry
 * point stays silent while looking like a measurement.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
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

#ifndef SYS_openat2
#define SYS_openat2 437
#endif

struct svp_open_how {
	unsigned long long flags;
	unsigned long long mode;
	unsigned long long resolve;
};

static const char *runid;

static void mk(char *out, size_t n, const char *what)
{
	snprintf(out, n, "SVP-%s-%s", runid, what);
}

/*
 * The legacy syscalls are absent on some architectures, and a probe that stays
 * silent there is not a defect. Saying out loud which ones were actually issued
 * is what keeps that exemption from covering a genuinely broken probe: the
 * checker demotes a check to "skip" only for a syscall reported as unavailable.
 */
static void issued(const char *name, long rc)
{
	if (rc < 0 && errno == ENOSYS)
		printf("SKIPPED %s reason=ENOSYS\n", name);
	else
		printf("ISSUED %s rc=%ld\n", name, rc);
}

#if !defined(SYS_open) || !defined(SYS_unlink)
static void unavailable(const char *name)
{
	printf("SKIPPED %s reason=no-syscall-number\n", name);
}
#endif

static void exec_copy(const char *src, const char *path, int use_execveat)
{
	char buf[65536];
	ssize_t n;
	int in, out;
	pid_t pid;

	in = open(src, O_RDONLY);
	if (in < 0)
		return;
	out = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0755);
	if (out < 0) {
		close(in);
		return;
	}
	while ((n = read(in, buf, sizeof(buf))) > 0) {
		if (write(out, buf, n) != n)
			break;
	}
	close(in);
	close(out);

	pid = fork();
	if (pid == 0) {
		char *const argv[] = { (char *)path, NULL };
		char *const envp[] = { NULL };

		if (use_execveat)
			syscall(SYS_execveat, AT_FDCWD, path, argv, envp, 0);
		else
			syscall(SYS_execve, path, argv, envp);
		_exit(127);
	}
	if (pid > 0) {
		const char *name = use_execveat ? "execveat" : "execve";
		int st;

		waitpid(pid, &st, 0);
		/* The syscall does not return on success, so the child's exit
		   status is the only evidence it was reached. */
		if (WIFEXITED(st) && WEXITSTATUS(st) == 127)
			printf("FAILED %s\n", name);
		else
			printf("ISSUED %s rc=0\n", name);
	}
}

int main(int argc, char **argv)
{
	char path[256], buf[256];
	struct svp_open_how how;
	struct iovec iov;
	struct sockaddr_in sa;
	int fd, s, port;
	long rc;

	runid = argc > 1 ? argv[1] : "probecheck";
	port = argc > 2 ? atoi(argv[2]) : 27000;

	setvbuf(stdout, NULL, _IOLBF, 0);

#ifdef SYS_open
	mk(path, sizeof(path), "pc-open.dat");
	rc = syscall(SYS_open, path, O_RDWR | O_CREAT, 0600);
	issued("open", rc);
	if (rc >= 0)
		close((int)rc);
#else
	unavailable("open");
#endif

	mk(path, sizeof(path), "pc-openat.dat");
	fd = syscall(SYS_openat, AT_FDCWD, path, O_RDWR | O_CREAT, 0600);
	issued("openat", fd);

	mk(path, sizeof(path), "pc-openat2.dat");
	memset(&how, 0, sizeof(how));
	how.flags = O_RDWR | O_CREAT;
	how.mode = 0600;
	{
		int fd2 = syscall(SYS_openat2, AT_FDCWD, path, &how, sizeof(how));

		issued("openat2", fd2);
		if (fd2 >= 0)
			close(fd2);
	}

	mk(buf, sizeof(buf), "pc-write");
	strcat(buf, "\n");
	if (fd >= 0)
		issued("write", syscall(SYS_write, fd, buf, strlen(buf) + 1));

	mk(buf, sizeof(buf), "pc-pwritev");
	strcat(buf, "\n");
	iov.iov_base = buf;
	iov.iov_len = strlen(buf) + 1;
	if (fd >= 0)
		issued("pwritev", syscall(SYS_pwritev, fd, &iov, 1, 0));

	mk(buf, sizeof(buf), "pc-writev");
	strcat(buf, "\n");
	iov.iov_base = buf;
	iov.iov_len = strlen(buf) + 1;
	if (fd >= 0)
		issued("writev", syscall(SYS_writev, fd, &iov, 1));

	mk(buf, sizeof(buf), "pc-pwrite64");
	strcat(buf, "\n");
	if (fd >= 0)
		issued("pwrite64",
		       syscall(SYS_pwrite64, fd, buf, strlen(buf) + 1, 0));
	if (fd >= 0)
		close(fd);

#ifdef SYS_unlink
	mk(path, sizeof(path), "pc-open.dat");
	issued("unlink", syscall(SYS_unlink, path));
#else
	unavailable("unlink");
#endif

	mk(path, sizeof(path), "pc-openat.dat");
	issued("unlinkat", syscall(SYS_unlinkat, AT_FDCWD, path, 0));

	s = socket(AF_INET, SOCK_STREAM, 0);
	if (s >= 0) {
		memset(&sa, 0, sizeof(sa));
		sa.sin_family = AF_INET;
		sa.sin_port = htons(port);
		inet_pton(AF_INET, "127.0.0.1", &sa.sin_addr);
		issued("connect", syscall(SYS_connect, s, &sa, sizeof(sa)));
		close(s);
	}

	if (argc > 3) {
		mk(path, sizeof(path), "pc-execve.bin");
		exec_copy(argv[3], path, 0);
		mk(path, sizeof(path), "pc-execveat.bin");
		exec_copy(argv[3], path, 1);
	}

	printf("PROBECHECK-DONE\n");
	return 0;
}
