# Nixonator NixOS Wrapper Module (C Re-implementation)

# Compiles a native C executable shadowing/wrapping nixos-rebuild.

{
  config,
  lib,
  pkgs,
  ...
}:
let
  cSource = pkgs.writeText "nixonator.c" ''
    #define _GNU_SOURCE /* open_memstream(), used to capture summaries before printing them */
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <unistd.h>
    #include <sys/types.h>
    #include <sys/wait.h>
    #include <sys/stat.h>
    #include <pwd.h>
    #include <time.h>
    #include <ctype.h>

    /* ANSI Color Codes */
    #define RED "\033[1;31m"
    #define GREEN "\033[1;32m"
    #define YELLOW "\033[1;33m"
    #define BLUE "\033[1;34m"
    #define CYAN "\033[1;36m"
    #define MAGENTA "\033[1;35m"
    #define DIM "\033[2m"
    #define BOLD "\033[1m"
    #define RESET "\033[0m"

    /* Binary dependencies resolved at build time by Nix */
    #define PATH_NIX "${pkgs.nix}/bin/nix"
    #define PATH_NVD "${pkgs.nvd}/bin/nvd"
    #define PATH_NOM "${pkgs.nix-output-monitor}/bin/nom"
    #define PATH_NIXOS_REBUILD "${pkgs.nixos-rebuild}/bin/nixos-rebuild"
    #define PATH_GIT "${pkgs.git}/bin/git"
    #define PATH_CURL "${pkgs.curl}/bin/curl"

    typedef struct {
      char pre_install_summary[16];
      char summary_style[32];      /* zypper, grid, list */
      char hide_debug_logs[16];    /* true, format, false */
      char confirm_update[16];
      char pretty_git_summary[16];
      char show_gc_stats[16];
      char prompt_untracked[16];   /* ask, always, never */
      char ssh_key_path[512];
      char git_branch[128];
      char repo_url[512];
      char git_user_name[128];
      char git_user_email[128];
      char gpg_signing_key[128];
      char auto_gc[16];
      char gc_days[16];
    } Config;

    static void info(const char *msg) { printf(BLUE ">" RESET " %s\n", msg); }
    static void success(const char *msg) { printf(GREEN ">" RESET " %s\n", msg); }
    static void warn(const char *msg) { printf(YELLOW "> [Warning]" RESET " %s\n", msg); }
    static void err(const char *msg) { printf(RED "> [Error]" RESET " %s\n", msg); }
    static void debug_msg(const char *msg) { printf(DIM MAGENTA "[debug]" RESET DIM " %s" RESET "\n", msg); }

    /* --nxn-verbose: trace every command the wrapper runs and surface the output
     * of the ones whose output is normally captured and hidden. */
    static int verbose_mode = 0;

    static void verbose_cmd(const char *cmd) {
      if (verbose_mode) {
        /* Flush pending stdout first so traces stay in order when piped. */
        fflush(stdout);
        fprintf(stderr, DIM MAGENTA "[nixonator]" RESET DIM " $ %s" RESET "\n", cmd);
        fflush(stderr);
      }
    }

    /* Keeps stderr of internal commands visible under --nxn-verbose, so a failing
     * nix/nvd invocation explains itself instead of being swallowed. */
    static const char *quiet_suffix(void) {
      return verbose_mode ? "" : " 2>/dev/null";
    }

    static int nxn_system(const char *cmd) {
      verbose_cmd(cmd);
      return system(cmd);
    }

    static char *trim(char *str) {
      if (!str) return str;
      while (isspace((unsigned char)*str)) str++;
      if (*str == 0) return str;
      char *end = str + strlen(str) - 1;
      while (end > str && (isspace((unsigned char)*end) || *end == '"' || *end == 39)) {
        *end = '\0';
        end--;
      }
      if (*str == '"' || *str == 39) str++;
      return str;
    }

    static void load_config(const char *filepath, Config *cfg) {
      memset(cfg, 0, sizeof(Config));

      /* Set defaults */
      strcpy(cfg->pre_install_summary, "true");
      strcpy(cfg->summary_style, "zypper");
      strcpy(cfg->hide_debug_logs, "true");
      strcpy(cfg->confirm_update, "false");
      strcpy(cfg->pretty_git_summary, "true");
      strcpy(cfg->show_gc_stats, "true");
      strcpy(cfg->prompt_untracked, "ask");
      strcpy(cfg->git_branch, "main");
      strcpy(cfg->auto_gc, "false");
      strcpy(cfg->gc_days, "7");

      FILE *f = fopen(filepath, "r");
      if (!f) {
        err("No nixonator.conf found!");
        printf("Please run the installation setup script first:\n");
        printf("  sudo bash <(curl -sL https://raw.githubusercontent.com/usr40k/nixonator/refs/heads/main/install.sh)\n");
        exit(1);
      }

      char line[1024];
      while (fgets(line, sizeof(line), f)) {
        char *p = line;
        while (isspace((unsigned char)*p)) p++;
        if (*p == '#' || *p == '\0' || *p == '\n') continue;

        char *eq = strchr(p, '=');
        if (!eq) continue;

        *eq = '\0';
        char *key = trim(p);
        char *val = trim(eq + 1);

        if (strcmp(key, "PRE_INSTALL_SUMMARY") == 0) strncpy(cfg->pre_install_summary, val, sizeof(cfg->pre_install_summary) - 1);
        else if (strcmp(key, "SUMMARY_STYLE") == 0) strncpy(cfg->summary_style, val, sizeof(cfg->summary_style) - 1);
        else if (strcmp(key, "HIDE_DEBUG_LOGS") == 0) strncpy(cfg->hide_debug_logs, val, sizeof(cfg->hide_debug_logs) - 1);
        else if (strcmp(key, "CONFIRM_UPDATE") == 0) strncpy(cfg->confirm_update, val, sizeof(cfg->confirm_update) - 1);
        else if (strcmp(key, "PRETTY_GIT_SUMMARY") == 0) strncpy(cfg->pretty_git_summary, val, sizeof(cfg->pretty_git_summary) - 1);
        else if (strcmp(key, "SHOW_GC_STATS") == 0) strncpy(cfg->show_gc_stats, val, sizeof(cfg->show_gc_stats) - 1);
        else if (strcmp(key, "PROMPT_UNTRACKED") == 0) strncpy(cfg->prompt_untracked, val, sizeof(cfg->prompt_untracked) - 1);
        else if (strcmp(key, "SSH_KEY_PATH") == 0) strncpy(cfg->ssh_key_path, val, sizeof(cfg->ssh_key_path) - 1);
        else if (strcmp(key, "GIT_BRANCH") == 0) strncpy(cfg->git_branch, val, sizeof(cfg->git_branch) - 1);
        else if (strcmp(key, "REPO_URL") == 0) strncpy(cfg->repo_url, val, sizeof(cfg->repo_url) - 1);
        else if (strcmp(key, "GIT_USER_NAME") == 0) strncpy(cfg->git_user_name, val, sizeof(cfg->git_user_name) - 1);
        else if (strcmp(key, "GIT_USER_EMAIL") == 0) strncpy(cfg->git_user_email, val, sizeof(cfg->git_user_email) - 1);
        else if (strcmp(key, "GPG_SIGNING_KEY") == 0) strncpy(cfg->gpg_signing_key, val, sizeof(cfg->gpg_signing_key) - 1);
        else if (strcmp(key, "AUTO_GC") == 0) strncpy(cfg->auto_gc, val, sizeof(cfg->auto_gc) - 1);
        else if (strcmp(key, "GC_DAYS") == 0) strncpy(cfg->gc_days, val, sizeof(cfg->gc_days) - 1);
      }
      fclose(f);
    }

    static int update_config_key(const char *filepath, const char *key, const char *val) {
      FILE *f = fopen(filepath, "r");
      if (!f) return 0;

      char temp_path[512];
      snprintf(temp_path, sizeof(temp_path), "%s.tmp", filepath);
      FILE *out = fopen(temp_path, "w");
      if (!out) { fclose(f); return 0; }

      char line[1024];
      int key_found = 0;
      char key_prefix[256];
      snprintf(key_prefix, sizeof(key_prefix), "%s=", key);

      while (fgets(line, sizeof(line), f)) {
        char *p = line;
        while (isspace((unsigned char)*p)) p++;
        if (strncmp(p, key_prefix, strlen(key_prefix)) == 0) {
          fprintf(out, "%s=\"%s\"\n", key, val);
          key_found = 1;
        } else {
          fputs(line, out);
        }
      }
      if (!key_found) {
        fprintf(out, "%s=\"%s\"\n", key, val);
      }

      fclose(f);
      fclose(out);
      rename(temp_path, filepath);
      return 1;
    }

    /* Runs `cmd` and captures its stdout. With --nxn-verbose the captured output
     * (which is otherwise invisible) is echoed to stderr. */
    static int exec_cmd_captured(const char *cmd, char *out_buf, size_t buf_size) {
      if (out_buf) out_buf[0] = '\0';
      verbose_cmd(cmd);
      FILE *fp = popen(cmd, "r");
      if (!fp) return -1;

      if (out_buf && buf_size > 0) {
        size_t bytes_read = fread(out_buf, 1, buf_size - 1, fp);
        out_buf[bytes_read] = '\0';
        /* Strip trailing newline */
        while (bytes_read > 0 && (out_buf[bytes_read - 1] == '\n' || out_buf[bytes_read - 1] == '\r')) {
          out_buf[--bytes_read] = '\0';
        }
      }

      int status = pclose(fp);

      if (verbose_mode) {
        if (out_buf != NULL && out_buf[0] != '\0') {
          fprintf(stderr, DIM "    -> %s" RESET "\n", out_buf);
        } else {
          fprintf(stderr, DIM "    -> (no output)" RESET "\n");
        }
        fflush(stderr);
      }

      return status;
    }

    static int filter_and_pipe_command(const char *cmd, const char *hide_debug_mode, int use_nom) {
      verbose_cmd(cmd);
      int pipefd[2];
      if (pipe(pipefd) < 0) {
        perror("pipe");
        return 1;
      }

      pid_t pid = fork();
      if (pid < 0) {
        perror("fork");
        return 1;
      }

      if (pid == 0) {
        /* Child: execute command writing to pipe write end */
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        dup2(pipefd[1], STDERR_FILENO);
        close(pipefd[1]);

        execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
        exit(127);
      }

      /* Parent: read from pipefd[0] line by line, filter debug logs, and pipe into nom or stdout */
      close(pipefd[1]);
      FILE *in = fdopen(pipefd[0], "r");

      FILE *nom_in = NULL;
      pid_t nom_pid = -1;

      if (use_nom) {
        int nom_pipe[2];
        if (pipe(nom_pipe) == 0) {
          nom_pid = fork();
          if (nom_pid == 0) {
            close(nom_pipe[1]);
            dup2(nom_pipe[0], STDIN_FILENO);
            close(nom_pipe[0]);
            execl(PATH_NOM, "nom", "--json", (char *)NULL);
            exit(127);
          }
          close(nom_pipe[0]);
          nom_in = fdopen(nom_pipe[1], "w");
        }
      }

      char line[2048];
      while (fgets(line, sizeof(line), in)) {
        char *p = line;
        while (isspace((unsigned char)*p)) p++;

        int is_debug = (strncmp(p, "debug:", 6) == 0);

        if (is_debug) {
          if (strcmp(hide_debug_mode, "format") == 0) {
            debug_msg(p + 6);
          } else if (strcmp(hide_debug_mode, "false") == 0) {
            if (nom_in) { fputs(line, nom_in); fflush(nom_in); }
            else { fputs(line, stdout); fflush(stdout); }
          }
        } else {
          if (nom_in) { fputs(line, nom_in); fflush(nom_in); }
          else { fputs(line, stdout); fflush(stdout); }
        }
      }

      fclose(in);
      if (nom_in) fclose(nom_in);

      int status = 0;
      waitpid(pid, &status, 0);
      if (nom_pid > 0) waitpid(nom_pid, NULL, 0);

      return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
    }

    /* How many entries per category the summary keeps. nvd can report hundreds
     * of packages on a nixpkgs bump, so listings are capped but counted in full. */
    #define MAX_SUMMARY_ITEMS 256

    typedef enum {
      CAT_NONE = 0,
      CAT_ADDED,
      CAT_UPGRADED,
      CAT_CHANGED,
      CAT_REMOVED
    } PackageCategory;

    /* nvd renders one package per line as "[<install-state><selection-state>]",
     * e.g. [A+] added and newly selected, [A.] added dependency, [U*] upgraded,
     * [R-] removed and newly unselected, [C-] selection state changed.
     * The install state character is one of (see nvd's own source):
     * I installed/unchanged, A added, R removed, U upgraded, D downgraded,
     * C changed version or selection state. */
    static PackageCategory category_for_install_state(char install_state) {
      switch (install_state) {
        case 'A': return CAT_ADDED;
        case 'R': return CAT_REMOVED;
        case 'U': return CAT_UPGRADED;
        case 'D':
        case 'C': return CAT_CHANGED;
        default: return CAT_NONE; /* 'I' is unchanged; anything else unknown */
      }
    }

    /* Resolves the target system's toplevel store path for `flake_ref`.
     *
     * `nix eval ...outPath` only returns the path the build *would* produce, so a
     * fresh configuration gives a path that is not in the store yet - and
     * `nvd diff` refuses to compare paths that do not exist ("Path does not
     * exist: ..."), which is why the delta used to come out empty. So when the
     * path is missing we build it here; `nixos-rebuild` would build exactly the
     * same derivation moments later, so the work is reused from the store (and
     * this also pre-warms the system build before the confirmation prompt).
     *
     * Returns 1 on success, 0 when the reference could not be evaluated, or -1
     * when it evaluated but could not be built. */
    static int resolve_target_profile(const char *flake_ref, char *out_path, size_t out_size) {
      char cmd[4096];

      out_path[0] = '\0';
      snprintf(cmd, sizeof(cmd),
        "%s eval --impure --raw --extra-experimental-features \"nix-command flakes\" \"%s.outPath\"%s",
        PATH_NIX, flake_ref, quiet_suffix());
      if (exec_cmd_captured(cmd, out_path, out_size) != 0) out_path[0] = '\0';
      if (out_path[0] == '\0') return 0;

      if (access(out_path, F_OK) == 0) return 1;

      info("Target system is not built yet; building it so the package delta can be computed...");
      /* --no-link keeps `nix build` from dropping a ./result symlink in /etc/nixos. */
      snprintf(cmd, sizeof(cmd),
        "%s build --no-link --print-out-paths --impure --extra-experimental-features \"nix-command flakes\" \"%s\"%s",
        PATH_NIX, flake_ref, quiet_suffix());
      if (exec_cmd_captured(cmd, out_path, out_size) != 0) out_path[0] = '\0';
      /* --print-out-paths can itself return an unrealised path, so only trust
       * access() *after* the build above has run. */
      if (out_path[0] == '\0' || access(out_path, F_OK) != 0) return -1;
      return 1;
    }

    /* Package diff generator, ported from the original shell wrapper: renders the
     * pre-rebuild package delta summary into `out` (stdout or an in-memory stream).
     * Returns the number of pending package operations found, 0 when the system
     * closure already matches, or -1 when the delta could not be computed at all. */
    static int format_package_summary(const char *config_dir, const char *hostname, const Config *cfg, FILE *out) {
      char current_sys[1024] = {0};

      /* Check active running system path first, fallback to current system profile */
      if (access("/run/current-system", F_OK) == 0) {
        strncpy(current_sys, "/run/current-system", sizeof(current_sys) - 1);
      } else if (access("/nix/var/nix/profiles/system", F_OK) == 0) {
        strncpy(current_sys, "/nix/var/nix/profiles/system", sizeof(current_sys) - 1);
      } else {
        fprintf(out, "  " DIM "(No active running system or system profile found for diff calculation)" RESET "\n");
        return -1;
      }

      char target_path[1024] = {0};
      char flake_ref[1024] = {0};
      int resolved = 0;

      /* Try the same flake references the shell version used: the explicit
       * nixosConfigurations attribute first, then the flake's default output. */
      snprintf(flake_ref, sizeof(flake_ref),
        "path:%s#nixosConfigurations.%s.config.system.build.toplevel", config_dir, hostname);
      resolved = resolve_target_profile(flake_ref, target_path, sizeof(target_path));

      if (resolved == 0) {
        snprintf(flake_ref, sizeof(flake_ref), ".#nixosConfigurations.%s.config.system.build.toplevel", hostname);
        resolved = resolve_target_profile(flake_ref, target_path, sizeof(target_path));
      }

      if (resolved == 0) {
        snprintf(flake_ref, sizeof(flake_ref), "path:%s#%s.config.system.build.toplevel", config_dir, hostname);
        resolved = resolve_target_profile(flake_ref, target_path, sizeof(target_path));
      }

      if (resolved == 0) {
        snprintf(flake_ref, sizeof(flake_ref), ".#%s.config.system.build.toplevel", hostname);
        resolved = resolve_target_profile(flake_ref, target_path, sizeof(target_path));
      }

      if (resolved < 0) {
        fprintf(out, "  " RED "(The target system failed to build, so no package delta is available)" RESET "\n");
        return -1;
      }

      if (resolved == 0) {
        fprintf(out, "  " YELLOW "(Could not calculate target closure diff before rebuild)" RESET "\n");
        return -1;
      }

      /* Calculate diff between system path and target configuration path */
      char nvd_cmd[2048];
      snprintf(nvd_cmd, sizeof(nvd_cmd), "%s diff \"%s\" \"%s\"%s", PATH_NVD, current_sys, target_path, quiet_suffix());

      FILE *fp = popen(nvd_cmd, "r");
      if (!fp) {
        fprintf(out, "  " YELLOW "(Failed to execute nvd diff)" RESET "\n");
        return -1;
      }

      char added[MAX_SUMMARY_ITEMS][256], upgraded[MAX_SUMMARY_ITEMS][256];
      char changed[MAX_SUMMARY_ITEMS][256], removed[MAX_SUMMARY_ITEMS][256];
      int num_add = 0, num_upg = 0, num_chg = 0, num_rem = 0;
      int total_add = 0, total_upg = 0, total_chg = 0, total_rem = 0;
      int saw_package_lines = 0;
      int saw_no_changes_line = 0;
      PackageCategory section = CAT_NONE;
      char unparsed[3][256];
      int num_unparsed = 0;

      char line[1024];
      while (fgets(line, sizeof(line), fp)) {
        char *p = line;
        while (isspace((unsigned char)*p)) p++;
        if (*p == '\0' || *p == '\n') continue;

        if (strncmp(p, "debug:", 6) == 0) continue;

        if (*p != '[') {
          /* Section headings ("Added packages:", "Removed packages:",
           * "Version changes:", "Selection state changes:") decide the bucket for
           * the markers underneath them; any other heading resets back to
           * "unknown" so that the marker character decides instead. */
          size_t len = strlen(p);
          while (len > 0 && isspace((unsigned char)p[len - 1])) p[--len] = '\0';
          if (strstr(p, "No version or selection state changes") != NULL) {
            saw_no_changes_line = 1;
          } else if (len > 0 && p[len - 1] == ':') {
            if (strstr(p, "Added") != NULL) section = CAT_ADDED;
            else if (strstr(p, "Removed") != NULL) section = CAT_REMOVED;
            else if (strstr(p, "Selection state") != NULL) section = CAT_CHANGED;
            else section = CAT_NONE;
          } else if (len > 0 && strncmp(p, "<<<", 3) != 0 && strncmp(p, ">>>", 3) != 0
                     && strncmp(p, "Closure size:", 13) != 0) {
            /* Keep a few unrecognised lines: when nothing parses at all they are
             * usually the explanation (e.g. nvd's "Path does not exist: ..."). */
            if (num_unparsed < 3) {
              snprintf(unparsed[num_unparsed], sizeof(unparsed[0]), "%s", p);
              num_unparsed++;
            }
          }
          continue;
        }

        char *marker_end = strchr(p, ']');
        if (marker_end == NULL || marker_end - p > 8) continue;
        saw_package_lines++;

        PackageCategory cat = section;
        if (cat == CAT_NONE) cat = category_for_install_state(p[1]);
        if (cat == CAT_NONE) continue;

        /* Skip the "#<n>" counter column and lose nvd's column padding. */
        char *rest = marker_end + 1;
        while (*rest == ' ' || *rest == '\t') rest++;
        if (*rest == '#') {
          while (*rest != '\0' && !isspace((unsigned char)*rest)) rest++;
          while (*rest == ' ' || *rest == '\t') rest++;
        }

        char label[256];
        size_t label_len = 0;
        int last_was_space = 0;
        for (char *q = rest; *q != '\0' && *q != '\n' && *q != '\r'; q++) {
          if (isspace((unsigned char)*q)) {
            if (!last_was_space && label_len > 0 && label_len < sizeof(label) - 1) label[label_len++] = ' ';
            last_was_space = 1;
          } else {
            if (label_len < sizeof(label) - 1) label[label_len++] = *q;
            last_was_space = 0;
          }
        }
        while (label_len > 0 && label[label_len - 1] == ' ') label_len--;
        label[label_len] = '\0';
        if (label_len == 0) continue;

        if (cat == CAT_ADDED) {
          total_add++;
          if (num_add < MAX_SUMMARY_ITEMS) strcpy(added[num_add++], label);
        } else if (cat == CAT_UPGRADED) {
          total_upg++;
          if (num_upg < MAX_SUMMARY_ITEMS) strcpy(upgraded[num_upg++], label);
        } else if (cat == CAT_CHANGED) {
          total_chg++;
          if (num_chg < MAX_SUMMARY_ITEMS) strcpy(changed[num_chg++], label);
        } else {
          total_rem++;
          if (num_rem < MAX_SUMMARY_ITEMS) strcpy(removed[num_rem++], label);
        }
      }
      pclose(fp);

      int total = total_add + total_upg + total_chg + total_rem;
      if (total == 0) {
        if (saw_package_lines > 0 || saw_no_changes_line) {
          fprintf(out, "  " GREEN "No system package changes detected for this rebuild." RESET "\n");
          return 0;
        }
        /* Nothing recognisable came out of nvd: say so rather than claiming the
         * closure is unchanged (this is what a future nvd output change looks like). */
        fprintf(out, "  " YELLOW "(Could not parse a package diff from 'nvd diff' output)" RESET "\n");
        for (int i = 0; i < num_unparsed; i++) {
          fprintf(out, "    " DIM "%s" RESET "\n", unparsed[i]);
        }
        return -1;
      }

      /* Style names match the shell version: zypper/traditional, grid and
       * list (which is also the fallback for any unknown value). */
      if (strcmp(cfg->summary_style, "grid") == 0) {
        const char *grid_title = "PRE-REBUILD PACKAGE DELTA SUMMARY (System vs Target Config)";
        fprintf(out, "┌──────────────────────────────────────────────────────────────────────────────┐\n");
        fprintf(out, "│ " BOLD "%s" RESET "%*s│\n", grid_title, (int)(77 - strlen(grid_title)), "");
        fprintf(out, "├───────────┬──────────────────────────────────────────────────────────────────┤\n");
        fprintf(out, "│ " BOLD "ACTION    " RESET "│ " BOLD "PACKAGE DETAILS" RESET "                                                  │\n");
        fprintf(out, "├───────────┼──────────────────────────────────────────────────────────────────┤\n");
        for (int i = 0; i < num_add; i++) fprintf(out, "│ \033[1;32m%-9s\033[0m │ %-64.64s │\n", "[+ INST]", added[i]);
        for (int i = 0; i < num_upg; i++) fprintf(out, "│ \033[1;36m%-9s\033[0m │ %-64.64s │\n", "[^ UPGR]", upgraded[i]);
        for (int i = 0; i < num_chg; i++) fprintf(out, "│ \033[1;33m%-9s\033[0m │ %-64.64s │\n", "[~ CHNG]", changed[i]);
        for (int i = 0; i < num_rem; i++) fprintf(out, "│ \033[1;31m%-9s\033[0m │ %-64.64s │\n", "[- REMV]", removed[i]);
        fprintf(out, "└───────────┴──────────────────────────────────────────────────────────────────┘\n");
        fprintf(out, " Total pending package operations: " BOLD "%d" RESET "\n", total);
      } else if (strcmp(cfg->summary_style, "zypper") == 0 || strcmp(cfg->summary_style, "traditional") == 0) {
        /* zypper / traditional */
        fprintf(out, BOLD "Proposed Package Changes:" RESET "\n");
        if (num_add > 0) {
          fprintf(out, "\n" GREEN "The following %d NEW package(s) will be INSTALLED:" RESET "\n", total_add);
          for (int i = 0; i < num_add; i++) fprintf(out, "  " GREEN "+" RESET " %s\n", added[i]);
        }
        if (num_upg > 0) {
          fprintf(out, "\n" CYAN "The following %d package(s) will be UPGRADED:" RESET "\n", total_upg);
          for (int i = 0; i < num_upg; i++) fprintf(out, "  " CYAN "^" RESET " %s\n", upgraded[i]);
        }
        if (num_chg > 0) {
          fprintf(out, "\n" YELLOW "The following %d package(s) will be CHANGED/DOWNGRADED:" RESET "\n", total_chg);
          for (int i = 0; i < num_chg; i++) fprintf(out, "  " YELLOW "~" RESET " %s\n", changed[i]);
        }
        if (num_rem > 0) {
          fprintf(out, "\n" RED "The following %d package(s) will be REMOVED:" RESET "\n", total_rem);
          for (int i = 0; i < num_rem; i++) fprintf(out, "  " RED "-" RESET " %s\n", removed[i]);
        }
        fprintf(out, "\n" BOLD "Summary:" RESET " %d to install, %d to upgrade, %d changed, %d to remove.\n",
          total_add, total_upg, total_chg, total_rem);
      } else { /* list | * */
        fprintf(out, CYAN "••• Pending Package Operations (%d total) •••" RESET "\n", total);
        for (int i = 0; i < num_add; i++) fprintf(out, "  • " GREEN "[ADDED]" RESET " %s\n", added[i]);
        for (int i = 0; i < num_upg; i++) fprintf(out, "  • " CYAN "[UPGRADED]" RESET " %s\n", upgraded[i]);
        for (int i = 0; i < num_chg; i++) fprintf(out, "  • " YELLOW "[CHANGED]" RESET " %s\n", changed[i]);
        for (int i = 0; i < num_rem; i++) fprintf(out, "  • " RED "[REMOVED]" RESET " %s\n", removed[i]);
      }

      /* Be honest when a category had more entries than we keep. */
      if (total_add > num_add || total_upg > num_upg || total_chg > num_chg || total_rem > num_rem) {
        fprintf(out, "  " DIM "(%d change(s) in total; only the first %d of each category are listed)" RESET "\n",
          total, MAX_SUMMARY_ITEMS);
      }

      return total;
    }

    int main(int argc, char *argv[]) {
      const char *config_dir = "/etc/nixos";
      char modules_dir[512];
      snprintf(modules_dir, sizeof(modules_dir), "%s/modules", config_dir);

      if (chdir(config_dir) != 0) {
        perror("chdir /etc/nixos failed");
        return 1;
      }

      char nixonator_conf[512];
      snprintf(nixonator_conf, sizeof(nixonator_conf), "%s/nixonator/nixonator.conf", modules_dir);

      Config cfg;
      load_config(nixonator_conf, &cfg);

      char hostname[128] = {0};
      gethostname(hostname, sizeof(hostname));

      char host_dir[256];
      snprintf(host_dir, sizeof(host_dir), "hosts/%s", hostname);
      char host_lock[256];
      snprintf(host_lock, sizeof(host_lock), "%s/flake.lock", host_dir);

      mkdir("hosts", 0755);
      mkdir(host_dir, 0755);

      const char *sudo_user = getenv("SUDO_USER");
      if (sudo_user && strlen(sudo_user) > 0) {
        setenv("USER", sudo_user, 1);
      } else {
        struct passwd *pw = getpwuid(getuid());
        if (pw) setenv("USER", pw->pw_name, 1);
      }

      if (strlen(cfg.ssh_key_path) > 0) {
        char ssh_cmd[1024];
        snprintf(ssh_cmd, sizeof(ssh_cmd), "ssh -i %s -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new", cfg.ssh_key_path);
        setenv("GIT_SSH_COMMAND", ssh_cmd, 1);
      }

      char *tty = ttyname(STDIN_FILENO);
      if (tty) {
        setenv("GPG_TTY", tty, 1);
        nxn_system("command -v gpg-connect-agent >/dev/null 2>&1 && gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1 || true");
      }

      /* --nxn-verbose is Nixonator's own flag: scan for it up front so that it also
       * applies to the sub-commands handled in the loop below. */
      for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--nxn-verbose") == 0) verbose_mode = 1;
      }
      if (verbose_mode) {
        info("--nxn-verbose: tracing every command, with the output of captured commands");
      }

      int do_git = 1;
      char rebuild_args[2048] = {0};

      for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--no-git") == 0) {
          do_git = 0;
        } else if (strcmp(argv[i], "--nxn-verbose") == 0) {
          /* Already handled by the pre-scan above; never forwarded to nixos-rebuild. */
        } else if (strcmp(argv[i], "--upgrade") == 0) {
          char msg[512];
          snprintf(msg, sizeof(msg), "Updating flake inputs for " CYAN "%s" RESET "...", hostname);
          info(msg);

          struct stat st;
          if (stat(host_lock, &st) == 0) {
            nxn_system("cp hosts/\"$(hostname)\"/flake.lock flake.lock 2>/dev/null || true");
          } else if (stat("flake.lock", &st) == 0) {
            snprintf(msg, sizeof(msg), "cp flake.lock %s", host_lock);
            nxn_system(msg);
          }

          char up_cmd[1024];
          snprintf(up_cmd, sizeof(up_cmd), "%s flake update --log-format internal-json -v 2>&1", PATH_NIX);
          int ret = filter_and_pipe_command(up_cmd, cfg.hide_debug_logs, 1);

          if (ret != 0) {
            err("Flake update failed!");
            unlink("flake.lock");
            return ret;
          }

          snprintf(msg, sizeof(msg), "cp flake.lock %s", host_lock);
          nxn_system(msg);
          snprintf(msg, sizeof(msg), "Flake inputs successfully updated and locked for %s.", hostname);
          success(msg);
          return 0;
        } else if (strcmp(argv[i], "--nixonator-update") == 0) {
          info("Self-updating Nixonator module from remote repository...");
          mkdir("modules/nixonator", 0755);
          char curl_cmd[1024];
          snprintf(curl_cmd, sizeof(curl_cmd), "%s -sSL \"https://raw.githubusercontent.com/usr40k/nixonator/main/modules/nixonator/nixonator.nix\" -o modules/nixonator/nixonator.nix", PATH_CURL);
          if (nxn_system(curl_cmd) == 0) {
            success("Successfully updated modules/nixonator/nixonator.nix");
          } else {
            err("Failed to fetch remote nixonator.nix");
            return 1;
          }
          return 0;
        } else if (strcmp(argv[i], "--nuke") == 0) {
          if (i + 1 < argc && strcmp(argv[i + 1], "CONFIRM") == 0) {
            int reclone = 1;
            for (int j = 1; j < argc; j++) {
              if (strcmp(argv[j], "--no-reclone") == 0) reclone = 0;
            }

            warn("Nuking configuration directory (/etc/nixos)...");
            nxn_system("rm -rf .git hosts modules flake.nix flake.lock nixonator.conf 2>/dev/null || true");

            if (reclone) {
              char clone_cmd[1024];
              snprintf(clone_cmd, sizeof(clone_cmd), "%s clone \"%s\" .", PATH_GIT, cfg.repo_url);
              info("Re-cloning repository...");
              nxn_system(clone_cmd);
              success("Nuke complete! Please re-run your configuration setup.");
            } else {
              info("Skipping re-clone (--no-reclone passed).");
              success("Nuke complete! /etc/nixos is now empty.");
            }
            return 0;
          } else {
            err("Dangerous command! To confirm complete wipe and re-clone, run: sudo nixos-rebuild --nuke CONFIRM");
            err("By default this re-clones REPO_URL afterward. To skip that, add --no-reclone.");
            return 1;
          }
        } else {
          strcat(rebuild_args, " ");
          strcat(rebuild_args, argv[i]);
        }
      }

      struct stat st_lock;
      if (stat(host_lock, &st_lock) == 0) {
        char cp_cmd[512];
        snprintf(cp_cmd, sizeof(cp_cmd), "cp \"%s\" flake.lock 2>/dev/null || true", host_lock);
        nxn_system(cp_cmd);
      } else if (stat("flake.lock", &st_lock) == 0) {
        char cp_cmd[512];
        snprintf(cp_cmd, sizeof(cp_cmd), "cp flake.lock \"%s\" 2>/dev/null || true", host_lock);
        nxn_system(cp_cmd);
      }

      if (do_git) {
        struct stat st_git;
        if (stat(".git", &st_git) != 0) {
          char git_init[1024];
          snprintf(git_init, sizeof(git_init), "%s init && %s remote add origin \"%s\" && %s branch -M \"%s\"",
            PATH_GIT, PATH_GIT, cfg.repo_url, PATH_GIT, cfg.git_branch);
          nxn_system(git_init);
        }

        if (strlen(cfg.git_user_name) > 0) {
          char gcmd[512]; snprintf(gcmd, sizeof(gcmd), "%s config user.name \"%s\"", PATH_GIT, cfg.git_user_name); nxn_system(gcmd);
        }
        if (strlen(cfg.git_user_email) > 0) {
          char gcmd[512]; snprintf(gcmd, sizeof(gcmd), "%s config user.email \"%s\"", PATH_GIT, cfg.git_user_email); nxn_system(gcmd);
        }
        if (strlen(cfg.gpg_signing_key) > 0) {
          char gcmd[512];
          snprintf(gcmd, sizeof(gcmd), "%s config user.signingkey \"%s\" && %s config commit.gpgsign true", PATH_GIT, cfg.gpg_signing_key, PATH_GIT);
          nxn_system(gcmd);
        }

        int stashed = 0;
        if (nxn_system(PATH_GIT " diff-index --quiet HEAD -- 2>/dev/null") != 0) {
          info("Stashing local uncommitted changes...");
          nxn_system(PATH_GIT " stash push -m \"Nixonator auto-stash\" >/dev/null 2>&1");
          stashed = 1;
        }

        char fetch_cmd[512];
        snprintf(fetch_cmd, sizeof(fetch_cmd), "%s fetch origin \"%s\" || true", PATH_GIT, cfg.git_branch);
        nxn_system(fetch_cmd);

        char merge_cmd[512];
        snprintf(merge_cmd, sizeof(merge_cmd), "%s rev-parse --verify origin/\"%s\" >/dev/null 2>&1 && %s merge origin/\"%s\" --no-edit >/dev/null 2>&1 || true",
          PATH_GIT, cfg.git_branch, PATH_GIT, cfg.git_branch);
        nxn_system(merge_cmd);

        if (stashed) {
          nxn_system(PATH_GIT " stash pop >/dev/null 2>&1 || true");
        }

        /* Flag untracked files (intent-to-add) so Nix Flakes can evaluate them */
        nxn_system(PATH_GIT " add -N . >/dev/null 2>&1 || true");
      }

      time_t now = time(NULL);
      char timestamp[64];
      strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", localtime(&now));

      char prev_profile[512] = {0};
      ssize_t prev_len = readlink("/nix/var/nix/profiles/system", prev_profile, sizeof(prev_profile) - 1);
      if (prev_len != -1) prev_profile[prev_len] = '\0';

      char gen_cmd[512];
      char prev_gen_info[512] = {0};
      snprintf(gen_cmd, sizeof(gen_cmd), "%s-env -p /nix/var/nix/profiles/system --list-generations | grep '(current)' || true", PATH_NIX);
      exec_cmd_captured(gen_cmd, prev_gen_info, sizeof(prev_gen_info));

      char *pre_summary = NULL;
      size_t pre_summary_len = 0;
      int pre_summary_ok = 0;

      if (strcmp(cfg.pre_install_summary, "true") == 0) {
        printf(CYAN "──────────────────────────────────────────────────────────────────────────────" RESET "\n");
        printf(CYAN "Nixonator: pre-rebuild summary" RESET "\n");
        printf("  Host:          %s\n", hostname);
        printf("  Branch:        %s\n", cfg.git_branch);
        printf("  Flake target:  %s#%s\n", config_dir, hostname);

        char *extra_args = rebuild_args;
        while (*extra_args == ' ') extra_args++;
        printf("  Extra args:    %s\n", (*extra_args != '\0') ? extra_args : "(none)");

        struct stat st_git;
        if (stat(".git", &st_git) == 0) {
          char count_buf[64] = {0};
          snprintf(gen_cmd, sizeof(gen_cmd), "%s status --porcelain 2>/dev/null | wc -l", PATH_GIT);
          exec_cmd_captured(gen_cmd, count_buf, sizeof(count_buf));
          int pending = atoi(trim(count_buf));
          printf("  Local changes: %d file(s) not yet committed\n", pending);
          if (pending > 0) {
            snprintf(gen_cmd, sizeof(gen_cmd), "%s status --short 2>/dev/null | sed 's/^/    /'", PATH_GIT);
            nxn_system(gen_cmd);
          }
        }
        printf(CYAN "──────────────────────────────────────────────────────────────────────────────" RESET "\n");

        info("Silently evaluating target flake profile...");

        /* Render the package delta summary into memory first, so that the exact
         * same text can be shown here and embedded into the commit message below.
         * A negative status means the delta could not be computed at all; the note
         * is then only shown here and never recorded in the commit message. */
        FILE *summary_stream = open_memstream(&pre_summary, &pre_summary_len);
        if (summary_stream != NULL) {
          pre_summary_ok = (format_package_summary(config_dir, hostname, &cfg, summary_stream) >= 0);
          fclose(summary_stream);
        }
        if (pre_summary != NULL && pre_summary_len > 0) {
          fputs(pre_summary, stdout);
        }
        printf(CYAN "──────────────────────────────────────────────────────────────────────────────" RESET "\n");
      }

      if (strcmp(cfg.confirm_update, "true") == 0) {
        printf(YELLOW "Proceed with rebuild? [y/N]: " RESET);
        fflush(stdout);
        char ans[16] = {0};
        if (!fgets(ans, sizeof(ans), stdin) || (ans[0] != 'y' && ans[0] != 'Y')) {
          warn("Rebuild cancelled by user.");
          return 0;
        }
      }

      char start_msg[256];
      snprintf(start_msg, sizeof(start_msg), "Starting NixOS rebuild for " CYAN "%s" RESET "...", hostname);
      info(start_msg);

      char main_rebuild_cmd[4096];
      snprintf(main_rebuild_cmd, sizeof(main_rebuild_cmd),
        "%s %s --impure --flake \"%s#%s\" --log-format internal-json -v 2>&1",
        PATH_NIXOS_REBUILD, rebuild_args, config_dir, hostname);

      int rebuild_exit = filter_and_pipe_command(main_rebuild_cmd, cfg.hide_debug_logs, 1);

      if (rebuild_exit != 0) {
        err("NixOS rebuild failed! Changes will not be committed.");
        unlink("flake.lock");
        return rebuild_exit;
      }

      if (strcmp(cfg.auto_gc, "true") == 0) {
        char gc_msg[256];
        snprintf(gc_msg, sizeof(gc_msg), "Running automatic garbage collection (older than %s days)...", cfg.gc_days);
        info(gc_msg);

        char gc_wipe[512];
        snprintf(gc_wipe, sizeof(gc_wipe), "sudo nix profile wipe-history --older-than %sd >/dev/null 2>&1 || true", cfg.gc_days);
        nxn_system(gc_wipe);

        if (strcmp(cfg.show_gc_stats, "true") == 0) {
          char gc_cmd[512];
          snprintf(gc_cmd, sizeof(gc_cmd), "nix-collect-garbage --delete-older-than %sd 2>&1", cfg.gc_days);
          FILE *gc_fp = popen(gc_cmd, "r");
          char gc_stats[512] = {0};
          if (gc_fp) {
            char gc_line[1024];
            while (fgets(gc_line, sizeof(gc_line), gc_fp)) {
              if (strstr(gc_line, "freed") || strstr(gc_line, "store paths deleted")) {
                strncpy(gc_stats, trim(gc_line), sizeof(gc_stats) - 1);
              }
            }
            pclose(gc_fp);
          }
          printf(CYAN "────────────────────────────────────────────" RESET "\n");
          printf(CYAN "Nixonator: garbage collection summary" RESET "\n");
          if (strlen(gc_stats) > 0) {
            printf("  " GREEN "%s" RESET "\n", gc_stats);
          } else {
            printf("  Nothing to collect (no generations older than %s days).\n", cfg.gc_days);
          }
          printf(CYAN "────────────────────────────────────────────" RESET "\n");
        } else {
          char gc_del[512];
          snprintf(gc_del, sizeof(gc_del), "nix-collect-garbage --delete-older-than %sd >/dev/null 2>&1 || true", cfg.gc_days);
          nxn_system(gc_del);
        }
      }

      char new_profile[512] = {0};
      ssize_t new_len = readlink("/nix/var/nix/profiles/system", new_profile, sizeof(new_profile) - 1);
      if (new_len != -1) new_profile[new_len] = '\0';

      char new_gen_info[512] = {0};
      snprintf(gen_cmd, sizeof(gen_cmd), "%s-env -p /nix/var/nix/profiles/system --list-generations | grep '(current)' || true", PATH_NIX);
      exec_cmd_captured(gen_cmd, new_gen_info, sizeof(new_gen_info));

      char package_diff[4096] = {0};
      if (strlen(prev_profile) > 0 && strlen(new_profile) > 0 && strcmp(prev_profile, new_profile) != 0) {
        char nvd_cmd[1024];
        snprintf(nvd_cmd, sizeof(nvd_cmd), "%s diff \"%s\" \"%s\" 2>&1", PATH_NVD, prev_profile, new_profile);
        exec_cmd_captured(nvd_cmd, package_diff, sizeof(package_diff));
      } else {
        strcpy(package_diff, "No package profile changes detected.");
      }

      if (do_git) {
        unlink("flake.lock");
        nxn_system(PATH_GIT " add -u");

        /* Handle untracked files */
        char untracked_buf[2048] = {0};
        snprintf(gen_cmd, sizeof(gen_cmd), "%s ls-files --others --exclude-standard", PATH_GIT);
        exec_cmd_captured(gen_cmd, untracked_buf, sizeof(untracked_buf));

        if (strlen(untracked_buf) > 0) {
          if (strcmp(cfg.prompt_untracked, "never") == 0) {
            info("Leaving untracked files untracked (PROMPT_UNTRACKED=never).");
          } else if (strcmp(cfg.prompt_untracked, "always") == 0) {
            char add_cmd[256];
            snprintf(add_cmd, sizeof(add_cmd), "%s add %s", PATH_GIT, untracked_buf);
            nxn_system(add_cmd);
          } else {
            char *file = strtok(untracked_buf, "\n");
            while (file) {
              file = trim(file);
              if (strlen(file) > 0) {
                printf(YELLOW "New untracked file: %s — add to repo? [y]es/[n]o/[a]lways: " RESET, file);
                fflush(stdout);
                char uans[16] = {0};
                if (fgets(uans, sizeof(uans), stdin)) {
                  if (uans[0] == 'y' || uans[0] == 'Y') {
                    char add_cmd[512];
                    snprintf(add_cmd, sizeof(add_cmd), "%s add \"%s\"", PATH_GIT, file);
                    nxn_system(add_cmd);
                  } else if (uans[0] == 'a' || uans[0] == 'A') {
                    char add_cmd[512];
                    snprintf(add_cmd, sizeof(add_cmd), "%s add \"%s\"", PATH_GIT, file);
                    nxn_system(add_cmd);
                    strcpy(cfg.prompt_untracked, "always");
                    update_config_key(nixonator_conf, "PROMPT_UNTRACKED", "always");
                    info("PROMPT_UNTRACKED set to \"always\" in nixonator.conf.");
                  }
                }
              }
              file = strtok(NULL, "\n");
            }
          }
        }

        if (nxn_system(PATH_GIT " diff --cached --quiet 2>/dev/null") != 0) {
            info("Committing configuration changes...");
        
            // 1. Capture the staged file diff dynamically so it can go into the commit message
            size_t file_buffer_size = 4096;
            char *file_diff = malloc(file_buffer_size);
            int file_diff_allocated = 0;
            if (file_diff != NULL) {
                file_diff_allocated = 1;
                file_diff[0] = '\0';
                char cmd[512];
                snprintf(cmd, sizeof(cmd), "%s diff --cached --stat 2>/dev/null || true", PATH_GIT);
        
                FILE *fp = popen(cmd, "r");
                if (fp != NULL) {
                    size_t total_read = 0;
                    char read_buf[256];
                    
                    while (fgets(read_buf, sizeof(read_buf), fp) != NULL) {
                        size_t len = strlen(read_buf);
                        if (total_read + len >= file_buffer_size - 1) {
                            file_buffer_size *= 2;
                            char *temp = realloc(file_diff, file_buffer_size);
                            if (temp == NULL) break;
                            file_diff = temp;
                        }
                        strcpy(file_diff + total_read, read_buf);
                        total_read += len;
                    }
                    pclose(fp);
                }
            } else {
                file_diff = ""; // Fallback if allocation fails
            }
        
            // 2. Build the commit message (including the captured pre-rebuild package
            //    summary) and pipe it into git, so that long summaries and special
            //    characters never need to be shell-escaped.
            FILE *commit_in = popen(PATH_GIT " commit -F - >/dev/null 2>&1", "w");
            if (commit_in != NULL) {
                const char *trigger_user = getenv("USER");
                fprintf(commit_in, "NixOS System Update: %s - %s\n\n", hostname, timestamp);
                fprintf(commit_in, "### System Metadata\n");
                fprintf(commit_in, "- Hostname: %s\n", hostname);
                fprintf(commit_in, "- Triggered By: %s\n", trigger_user ? trigger_user : "unknown");
                fprintf(commit_in, "- Timestamp: %s\n\n", timestamp);
                fprintf(commit_in, "### Generation Shift\n");
                fprintf(commit_in, "- Previous:\n  %s\n", prev_gen_info);
                fprintf(commit_in, "- Current:\n  %s\n\n", new_gen_info);
                if (pre_summary_ok && pre_summary != NULL && pre_summary_len > 0) {
                    fprintf(commit_in, "### Package Changes (Pre-Rebuild Delta Summary)\n%s\n\n", pre_summary);
                }
                fprintf(commit_in, "### Package Profile Diff (Post-Rebuild)\n%s\n\n", package_diff);
                fprintf(commit_in, "### Files Uploaded & Updated\n%s\n", file_diff);
                pclose(commit_in);
            } else {
                err("Failed to open a pipe to 'git commit'.");
            }
        
            // 3. Pretty git summary block (prints to stdout and matches old style)
            if (strcmp(cfg.pretty_git_summary, "true") == 0) {
                printf(CYAN "────────────────────────────────────────────" RESET "\n");
                printf(CYAN "Nixonator: git summary" RESET "\n");
                
                // Print the file diff to stdout (just like the old shell wrapper did)
                if (file_diff[0] != '\0') {
                    fputs(file_diff, stdout);
                } else {
                    // Fallback to running git show if file_diff wasn't captured
                    nxn_system(PATH_GIT " show --stat --format=\"  Commit: %h\" HEAD 2>/dev/null || true");
                }
                
                printf(CYAN "────────────────────────────────────────────" RESET "\n");
            }
        
            // 4. Clean up allocated memory for file_diff
            if (file_diff_allocated) {
                free(file_diff);
            }
        
        } else {
            info("No configuration file changes to commit.");
        }
        
        info("Pushing changes to GitHub...");
        char push_cmd[512];
        snprintf(push_cmd, sizeof(push_cmd), "%s push origin \"%s\" || true", PATH_GIT, cfg.git_branch);
        if (nxn_system(push_cmd) != 0) {
            warn("Failed to push to remote repository.");
        }
      } else {
        unlink("flake.lock");
      }

      if (pre_summary != NULL) free(pre_summary);

      success("Rebuild and sync completed successfully!");
      return 0;
    }


  '';

  nixonatorBin = pkgs.runCommandCC "nixos-rebuild" { } ''
    mkdir -p $out/bin
    $CC -O2 -Wno-unused-result -Wall ${cSource} -o $out/bin/nixos-rebuild
  '';
in
{
  environment.systemPackages = with pkgs; [
    nixonatorBin
    git
    gnupg
    nix-output-monitor
    nvd
  ];

  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };
}
