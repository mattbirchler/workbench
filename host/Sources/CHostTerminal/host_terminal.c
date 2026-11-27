#include "host_terminal.h"

#include <ghostty/vt.h>

#include <errno.h>
#include <stdio.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif

struct wb_terminal {
    GhosttyTerminal terminal;
    GhosttyKeyEncoder encoder;
    wb_reply_fn reply;
    void *userdata;
    bool brackets_paste;
    // The end of what was fed last, so a mode change split across two
    // reads is still seen.
    uint8_t tail[16];
    size_t tail_len;
};

static void on_write_pty(GhosttyTerminal terminal, void *userdata, const uint8_t *data, size_t len) {
    (void)terminal;
    wb_terminal *self = userdata;
    if (self->reply) self->reply(self->userdata, data, len);
}

// Says what kind of terminal this is, as Ghostty does, so programs turn on
// what they would in a real one.
static bool on_device_attributes(GhosttyTerminal terminal, void *userdata, GhosttyDeviceAttributes *out) {
    (void)terminal;
    (void)userdata;
    memset(out, 0, sizeof(*out));
    out->primary.conformance_level = 62;
    out->primary.features[0] = 22;
    out->primary.num_features = 1;
    out->secondary.device_type = 1;
    out->secondary.firmware_version = 10;
    return true;
}

wb_terminal *wb_terminal_new(uint16_t cols, uint16_t rows, wb_reply_fn reply, void *userdata) {
    wb_terminal *self = calloc(1, sizeof(wb_terminal));
    if (!self) return NULL;
    self->reply = reply;
    self->userdata = userdata;
    GhosttyResult made = ghostty_terminal_new(NULL, &self->terminal, cols, rows);
    if (made != GHOSTTY_SUCCESS) {
        fprintf(stderr, "workbench-host: couldn't make a terminal (%d)\n", (int)made);
        free(self);
        return NULL;
    }
    if (ghostty_key_encoder_new(NULL, &self->encoder) != GHOSTTY_SUCCESS) {
        fprintf(stderr, "workbench-host: couldn't make a key encoder\n");
        ghostty_terminal_free(self->terminal);
        free(self);
        return NULL;
    }
    ghostty_terminal_set(self->terminal, GHOSTTY_TERMINAL_OPT_USERDATA, self);
    ghostty_terminal_set(self->terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void *)on_write_pty);
    ghostty_terminal_set(self->terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, (const void *)on_device_attributes);
    return self;
}

void wb_terminal_free(wb_terminal *self) {
    if (!self) return;
    ghostty_key_encoder_free(self->encoder);
    ghostty_terminal_free(self->terminal);
    free(self);
}

// Looks for the program switching bracketed paste on or off: CSI ? 2004 h/l.
static void note_paste_mode(wb_terminal *self, const uint8_t *data, size_t len) {
    static const char on[] = "\x1b[?2004h", off[] = "\x1b[?2004l";
    const size_t mark = sizeof(on) - 1;
    uint8_t joined[sizeof(self->tail) + 64];
    // The seam between the last read and this one.
    size_t head = len < 64 ? len : 64;
    memcpy(joined, self->tail, self->tail_len);
    memcpy(joined + self->tail_len, data, head);
    size_t joined_len = self->tail_len + head;
    for (size_t i = 0; i + mark <= joined_len; i++) {
        if (memcmp(joined + i, on, mark) == 0) self->brackets_paste = true;
        else if (memcmp(joined + i, off, mark) == 0) self->brackets_paste = false;
    }
    for (size_t i = 0; i + mark <= len; i++) {
        if (data[i] != 0x1b) continue;
        if (memcmp(data + i, on, mark) == 0) self->brackets_paste = true;
        else if (memcmp(data + i, off, mark) == 0) self->brackets_paste = false;
    }
    size_t keep = len < mark - 1 ? len : mark - 1;
    if (keep == len && self->tail_len + len <= sizeof(self->tail)) {
        memcpy(self->tail + self->tail_len, data, len);
        self->tail_len += len;
        if (self->tail_len > mark - 1) {
            memmove(self->tail, self->tail + self->tail_len - (mark - 1), mark - 1);
            self->tail_len = mark - 1;
        }
    } else {
        memcpy(self->tail, data + len - keep, keep);
        self->tail_len = keep;
    }
}

void wb_terminal_feed(wb_terminal *self, const uint8_t *data, size_t len) {
    if (!len) return;
    note_paste_mode(self, data, len);
    ghostty_terminal_vt_write(self->terminal, data, len);
}

void wb_terminal_resize(wb_terminal *self, uint16_t cols, uint16_t rows) {
    ghostty_terminal_resize(self->terminal, cols, rows, 8, 16);
}

bool wb_terminal_brackets_paste(const wb_terminal *self) { return self->brackets_paste; }

static char *copied(const uint8_t *bytes, size_t len, size_t *out_len) {
    if (!bytes || !len) {
        *out_len = 0;
        return NULL;
    }
    char *copy = malloc(len + 1);
    if (!copy) {
        *out_len = 0;
        return NULL;
    }
    memcpy(copy, bytes, len);
    copy[len] = 0;
    *out_len = len;
    return copy;
}

char *wb_terminal_text(wb_terminal *self, size_t *len) {
    *len = 0;
    GhosttyFormatterTerminalOptions options = GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
    options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    options.trim = true;
    GhosttyFormatter formatter;
    if (ghostty_formatter_terminal_new(NULL, &formatter, self->terminal, options) != GHOSTTY_SUCCESS) return NULL;
    uint8_t *bytes = NULL;
    size_t count = 0;
    char *text = NULL;
    if (ghostty_formatter_format_alloc(formatter, NULL, &bytes, &count) == GHOSTTY_SUCCESS) {
        text = copied(bytes, count, len);
        ghostty_free(NULL, bytes, count);
    }
    ghostty_formatter_free(formatter);
    return text;
}

char *wb_terminal_title(wb_terminal *self, size_t *len) {
    *len = 0;
    GhosttyString title = {0};
    if (ghostty_terminal_get(self->terminal, GHOSTTY_TERMINAL_DATA_TITLE, &title) != GHOSTTY_SUCCESS) return NULL;
    return copied(title.ptr, title.len, len);
}

size_t wb_terminal_key(wb_terminal *self, wb_key key, int digit, int mods, char *out, size_t capacity) {
    static const GhosttyKey digits[] = {
        GHOSTTY_KEY_DIGIT_1, GHOSTTY_KEY_DIGIT_2, GHOSTTY_KEY_DIGIT_3, GHOSTTY_KEY_DIGIT_4, GHOSTTY_KEY_DIGIT_5,
        GHOSTTY_KEY_DIGIT_6, GHOSTTY_KEY_DIGIT_7, GHOSTTY_KEY_DIGIT_8, GHOSTTY_KEY_DIGIT_9,
    };
    GhosttyKey code;
    char text[2] = {0, 0};
    switch (key) {
    case WB_KEY_RETURN: code = GHOSTTY_KEY_ENTER; break;
    case WB_KEY_ESCAPE: code = GHOSTTY_KEY_ESCAPE; break;
    case WB_KEY_RIGHT: code = GHOSTTY_KEY_ARROW_RIGHT; break;
    case WB_KEY_DOWN: code = GHOSTTY_KEY_ARROW_DOWN; break;
    case WB_KEY_UP: code = GHOSTTY_KEY_ARROW_UP; break;
    case WB_KEY_BACKSPACE: code = GHOSTTY_KEY_BACKSPACE; break;
    case WB_KEY_TAB: code = GHOSTTY_KEY_TAB; break;
    case WB_KEY_N: code = GHOSTTY_KEY_N; text[0] = 'n'; break;
    case WB_KEY_DIGIT:
        if (digit < 1 || digit > 9) return 0;
        code = digits[digit - 1];
        text[0] = (char)('0' + digit);
        break;
    default: return 0;
    }
    GhosttyKeyEvent event;
    if (ghostty_key_event_new(NULL, &event) != GHOSTTY_SUCCESS) return 0;
    GhosttyMods ghostty_mods = 0;
    if (mods & WB_MOD_SHIFT) ghostty_mods |= GHOSTTY_MODS_SHIFT;
    if (mods & WB_MOD_CONTROL) ghostty_mods |= GHOSTTY_MODS_CTRL;
    ghostty_key_event_set_action(event, GHOSTTY_KEY_ACTION_PRESS);
    ghostty_key_event_set_key(event, code);
    ghostty_key_event_set_mods(event, ghostty_mods);
    if (text[0]) ghostty_key_event_set_utf8(event, text, 1);
    ghostty_key_encoder_setopt_from_terminal(self->encoder, self->terminal);
    size_t written = 0;
    GhosttyResult result = ghostty_key_encoder_encode(self->encoder, event, out, capacity, &written);
    ghostty_key_event_free(event);
    return result == GHOSTTY_SUCCESS ? written : 0;
}

pid_t wb_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
               uint16_t cols, uint16_t rows, int *master) {
    struct winsize size = {.ws_row = rows, .ws_col = cols};
    pid_t pid = forkpty(master, NULL, NULL, &size);
    if (pid == 0) {
        // The child: only plain system calls from here to exec.
        for (int sig = 1; sig < NSIG; sig++) signal(sig, SIG_DFL);
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        if (cwd && chdir(cwd) != 0) {
            const char *home = getenv("HOME");
            if (home) (void)chdir(home);
        }
        execve(path, argv, envp);
        _exit(127);
    }
    if (pid < 0) return -1;
    fcntl(*master, F_SETFD, FD_CLOEXEC);
    fcntl(*master, F_SETFL, fcntl(*master, F_GETFL) | O_NONBLOCK);
    return pid;
}

void wb_pty_resize(int master, uint16_t cols, uint16_t rows) {
    struct winsize size = {.ws_row = rows, .ws_col = cols};
    ioctl(master, TIOCSWINSZ, &size);
}
