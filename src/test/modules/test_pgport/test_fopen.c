/*
 * Test Windows fopen access, lifecycle and translation modes through libpgport.
 * Copyright (c) 2026, PostgreSQL Global Development Group
 */
#include "postgres_fe.h"

#ifdef WIN32
/* Keep a native CRT control, while the test path calls the port API explicitly. */
#undef fopen

static int	failures;

static FILE *
open_test(const char *path, const char *mode, bool native)
{
	return native ? fopen(path, mode) : pgwin32_fopen(path, mode);
}

static void
run_case(const char *path, const char *mode, bool existing, bool native)
{
	FILE	   *stream;
	char		raw[16] = {0};
	char		readback[16] = {0};
	char		expected[16];
	bool		append = mode[0] == 'a';
	bool		binary = strchr(mode, 'b') != NULL;
	bool		update = strchr(mode, '+') != NULL;
	bool		writing = mode[0] != 'r' || update;
	int			errors = 0;
	int			open_errno;
	size_t		n;
	LARGE_INTEGER size;

	if (remove(path) != 0 && errno != ENOENT)
	{
		fprintf(stderr, "cannot remove fixture: %s\n", strerror(errno));
		exit(2);
	}
	if (existing)
	{
		stream = fopen(path, "wb");
		if (!stream || fwrite("A", 1, 1, stream) != 1 || fclose(stream) != 0)
			exit(2);
	}
	errno = 0;
	stream = open_test(path, mode, native);
	open_errno = errno;
	if (!existing && mode[0] == 'r')
	{
		if (stream || open_errno != ENOENT)
			errors++;
		if (stream)
			fclose(stream);
		if (GetFileAttributesA(path) != INVALID_FILE_ATTRIBUTES)
			errors++;
		goto report;
	}
	if (!stream)
	{
		errors++;
		goto report;
	}
	if (!GetFileSizeEx((HANDLE) _get_osfhandle(_fileno(stream)), &size))
		exit(2);
	if (size.QuadPart != (existing && mode[0] != 'w' ? 1 : 0))
		errors++;
	if (fseek(stream, 0, SEEK_SET) != 0)
		errors++;
	if (writing)
	{
		if (fwrite("X\n", 1, 2, stream) != 2 || fflush(stream) != 0)
			errors++;
	}
	if (mode[0] == 'r' || update)
	{
		if (fseek(stream, 0, SEEK_SET) != 0)
			errors++;
		n = fread(readback, 1, sizeof(readback) - 1, stream);
		if (ferror(stream) ||
			strcmp(readback, !writing ? "A" : existing && append ? "AX\n" : "X\n") != 0)
			errors++;
	}
	if (fclose(stream) != 0)
		errors++;
	stream = fopen(path, "rb");
	if (!stream)
		exit(2);
	n = fread(raw, 1, sizeof(raw) - 1, stream);
	if (ferror(stream) || fclose(stream) != 0)
		exit(2);
	if (writing)
		snprintf(expected, sizeof(expected), "%sX%s", existing && append ? "A" : "", binary ? "\n" : "\r\n");
	else
		strlcpy(expected, "A", sizeof(expected));
	if (n != strlen(expected) || memcmp(raw, expected, n) != 0)
		errors++;

report:
	printf("%s %s %s errors=%d\n", existing ? "existing" : "missing",
		   mode, errors ? "FAIL" : "PASS", errors);
	failures += errors != 0;
	if (remove(path) != 0 && errno != ENOENT)
		exit(2);
}
#endif

int
main(int argc, char **argv)
{
#ifdef WIN32
	const char *modes[] = {
		"r+", "r+b", "rb+", "r+t", "rt+",
		"w+", "w+b", "wb+", "w+t", "wt+",
		"a+", "a+b", "ab+", "a+t", "at+",
		"r", "rb", "rt", "w", "wb", "wt", "a", "ab", "at"
	};
	bool		native;

	if (argc < 2 || argc > 3 || (argc == 3 && strcmp(argv[2], "--native") != 0))
	{
		fprintf(stderr, "usage: test_fopen fixture-path [--native]\n");
		return 2;
	}
	native = argc == 3;
	for (int i = 0; i < lengthof(modes); i++)
	{
		run_case(argv[1], modes[i], false, native);
		run_case(argv[1], modes[i], true, native);
	}
	printf("cases=48 failures=%d\n", failures);
	return failures ? 1 : 0;
#else
	return 0;
#endif
}
