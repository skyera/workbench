/* Native argv capture fixture: no network access or transfer operations. */
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

int wmain(int argc, wchar_t **argv) {
    const wchar_t *path = _wgetenv(L"REVIEW_ARGV_FILE");
    const wchar_t *failure = _wgetenv(L"REVIEW_TRANSFER_FAIL");
    FILE *output;
    int i;
    if (!path || !(output = _wfopen(path, L"wb"))) {
        perror("Cannot open REVIEW_ARGV_FILE capture");
        return 2;
    }
    fputc('[', output);
    for (i = 1; i < argc; ++i) {
        const wchar_t *p;
        if (i > 1) fputc(',', output);
        fputc('"', output);
        for (p = argv[i]; *p; ++p) {
            /* ASCII JSON with UTF-16 escapes also preserves surrogate pairs. */
            fprintf(output, "\\u%04x", (unsigned int)*p);
        }
        fputc('"', output);
    }
    fputc(']', output);
    if (fclose(output) != 0) {
        perror("Cannot finish argument capture");
        return 2;
    }
    if (failure && *failure) {
        fputs("permission denied\n", stderr);
        return 17;
    }
    return 0;
}
