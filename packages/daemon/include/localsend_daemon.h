#ifndef LOCALSEND_DAEMON_H
#define LOCALSEND_DAEMON_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Blocking; call on a background thread. 0 = stopped, 1 = error, 2 = panic.
 * Paths are UTF-8 NUL-terminated strings kept alive until this call returns. */
int32_t localsend_daemon_run(const char *config_path, const char *socket_path,
                            const char *token_file);
#ifdef __cplusplus
}
#endif
#endif
