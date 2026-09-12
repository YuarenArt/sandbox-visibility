/*
 * Workload generator. Runs inside the sandbox, including as PID 1 in a VM,
 * where the run id comes from /proc/cmdline.
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
 * Truth records the token that actually appears in the syscall argument, not a
 * token named after the operation: open and unlink work on the same path, so a
 * separate unlink token would never show up in any trace.
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
		/* The trailing NUL is part of the payload: the tracer reads the
		   buffer as a string and would otherwise copy adjacent memory
		   into the trace. */
		rc = write(fd, buf, strlen(buf) + 1);
		record("write", wtok, rc, rc < 0 ? errno : 0);
		if (rc > 0)
			c_write.succeeded++;

		/* read carries a descriptor, not a path: unobservable through
		   syscall arguments, recorded so the column reads "not
		   instrumented" rather than zero. */
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

/* An unreachable address would otherwise hang the generator for minutes of SYN
   retries, so one misconfigured environment would stall the whole testbed. */
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
 * Destination port encodes the repetition index: connect() carries no text
 * token, so the tracer identifies the operation by port. The address comes from
 * outside because in a VM 127.0.0.1 is the guest's own loopback and never
 * reaches the host, which would make the rows incomparable.
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
		/* Leave the copies behind: unlinking them would add exec-related
		   unlink events that no denominator accounts for. */
	}
}

static void report(const char *name, struct counters *c)
{
	/* Same stream when truth goes to stdout: printing twice would yield two
	   denominators per operation. */
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
	char addrbuf[64];

	read_runid();

	if (!addr || !*addr) {
		if (from_cmdline("svp_addr=", addrbuf, sizeof(addrbuf)))
			addr = addrbuf;
		else
			addr = "127.0.0.1";
	}

	/*
	 * Reuse the stdout FILE* instead of fopen("/dev/stdout"): two FILE* on
	 * one fd interleave their buffers and silently drop truth lines, which
	 * shrinks the denominator and makes recall look better than it is.
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


	if (truth != stdout)
		printf("runid %s\n", runid);
	fprintf(truth, "runid %s\n", runid);
	fprintf(truth, "connect addr=%s base_port=%d\n", addr, base_port);
	fprintf(truth, "start real=%lld mono=%lld\n", now_ns(CLOCK_REALTIME),
		now_ns(CLOCK_MONOTONIC));

	/*
	 * No-op mode for the negative control: same sandbox, same launch path,
	 * same run id, zero actions.
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
