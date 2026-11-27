// A terminal with no window, and the pseudo-terminal a program runs on.
//
// The Workbench host keeps one of these per agent session. What the agent
// draws goes into the terminal (Ghostty's engine, libghostty-vt), so the
// host can read the screen the way the Mac reads its on-screen terminal,
// and keys are encoded the way the terminal's current modes ask for.
#ifndef WORKBENCH_HOST_TERMINAL_H
#define WORKBENCH_HOST_TERMINAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

typedef struct wb_terminal wb_terminal;

/// Called with what the terminal answers a program's questions with
/// (which terminal are you, where is the cursor). Write it to the pty.
typedef void (*wb_reply_fn)(void *userdata, const uint8_t *data, size_t len);

wb_terminal *wb_terminal_new(uint16_t cols, uint16_t rows, wb_reply_fn reply, void *userdata);
void wb_terminal_free(wb_terminal *terminal);

/// Takes in what the program wrote.
void wb_terminal_feed(wb_terminal *terminal, const uint8_t *data, size_t len);
void wb_terminal_resize(wb_terminal *terminal, uint16_t cols, uint16_t rows);

/// The screen and scrollback as plain text, or the window title. The
/// caller frees the result with free(). NULL when there's nothing.
char *wb_terminal_text(wb_terminal *terminal, size_t *len);
char *wb_terminal_title(wb_terminal *terminal, size_t *len);

/// True while the program has asked for pasted text to be marked as such.
bool wb_terminal_brackets_paste(const wb_terminal *terminal);

typedef enum {
    WB_KEY_RETURN,
    WB_KEY_ESCAPE,
    WB_KEY_RIGHT,
    WB_KEY_DOWN,
    WB_KEY_UP,
    WB_KEY_BACKSPACE,
    WB_KEY_TAB,
    WB_KEY_N,
    /// 1 through 9: pass the number in `digit`.
    WB_KEY_DIGIT,
} wb_key;

#define WB_MOD_SHIFT 1
#define WB_MOD_CONTROL 2

/// The bytes a key press sends, given what the program has switched on.
/// Returns how many were written to `out`, or 0 if the key has none.
size_t wb_terminal_key(wb_terminal *terminal, wb_key key, int digit, int mods, char *out, size_t capacity);

/// Starts a program on a new pseudo-terminal. Returns its process id and
/// stores the terminal's descriptor in `master`, or returns -1.
pid_t wb_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
               uint16_t cols, uint16_t rows, int *master);
void wb_pty_resize(int master, uint16_t cols, uint16_t rows);

#endif
