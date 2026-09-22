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

    static int exec_cmd_captured(const char *cmd, char *out_buf, size_t buf_size) {
      if (out_buf) out_buf[0] = '\0';
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
      return pclose(fp);
    }

    static int filter_and_pipe_command(const char *cmd, const char *hide_debug_mode, int use_nom) {
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

    static void format_package_summary(const char *config_dir, const char *hostname, const Config *cfg) {
      char current_sys[1024] = {0};

      /* Check active running system path first, fallback to current system profile */
      if (access("/run/current-system", F_OK) == 0) {
        strncpy(current_sys, "/run/current-system", sizeof(current_sys) - 1);
      } else if (access("/nix/var/nix/profiles/system", F_OK) == 0) {
        strncpy(current_sys, "/nix/var/nix/profiles/system", sizeof(current_sys) - 1);
      } else {
        printf("  " DIM "(No active running system or system profile found for diff calculation)" RESET "\n");
        return;
      }

      char target_path[1024] = {0};
      char eval_cmd[2048];

      /* Evaluate the target configuration top-level build path */
      snprintf(eval_cmd, sizeof(eval_cmd),
        "%s eval --impure --raw --extra-experimental-features \"nix-command flakes\" \"path:%s#nixosConfigurations.%s.config.system.build.toplevel.outPath\" 2>/dev/null",
        PATH_NIX, config_dir, hostname);

      if (exec_cmd_captured(eval_cmd, target_path, sizeof(target_path)) != 0 || strlen(target_path) == 0) {
        snprintf(eval_cmd, sizeof(eval_cmd),
          "%s eval --impure --raw --extra-experimental-features \"nix-command flakes\" \".#nixosConfigurations.%s.config.system.build.toplevel.outPath\" 2>/dev/null",
          PATH_NIX, hostname);
        exec_cmd_captured(eval_cmd, target_path, sizeof(target_path));
      }

      if (strlen(target_path) == 0) {
        printf("  " YELLOW "(Could not calculate target closure diff before rebuild)" RESET "\n");
        return;
      }

      /* Calculate diff between system path and target configuration path */
      char nvd_cmd[2048];
      snprintf(nvd_cmd, sizeof(nvd_cmd), "%s diff \"%s\" \"%s\" 2>/dev/null", PATH_NVD, current_sys, target_path);

      FILE *fp = popen(nvd_cmd, "r");
      if (!fp) {
        printf("  " YELLOW "(Failed to execute nvd diff)" RESET "\n");
        return;
      }

      char added[256][256], upgraded[256][256], changed[256][256], removed[256][256];
      int num_add = 0, num_upg = 0, num_chg = 0, num_rem = 0;

      char line[1024];
      while (fgets(line, sizeof(line), fp)) {
        char *p = line;
        while (isspace((unsigned char)*p)) p++;
        if (*p == '\0') continue;

        if (strncmp(p, "debug:", 6) == 0) continue;

        if (strncmp(p, "[A]", 3) == 0 && num_add < 256) {
          strncpy(added[num_add++], trim(p + 3), 255);
        } else if (strncmp(p, "[U]", 3) == 0 && num_upg < 256) {
          strncpy(upgraded[num_upg++], trim(p + 3), 255);
        } else if (strncmp(p, "[C]", 3) == 0 && num_chg < 256) {
          strncpy(changed[num_chg++], trim(p + 3), 255);
        } else if (strncmp(p, "[D]", 3) == 0 && num_rem < 256) {
          strncpy(removed[num_rem++], trim(p + 3), 255);
        }
      }
      pclose(fp);

      int total = num_add + num_upg + num_chg + num_rem;
      if (total == 0) {
        printf("  " GREEN "No package changes detected between current system path and target config." RESET "\n");
        return;
      }

      if (strcmp(cfg->summary_style, "grid") == 0) {
        printf("┌──────────────────────────────────────────────────────────────────────────────┐\n");
        printf("│ " BOLD "PRE-REBUILD PACKAGE DELTA SUMMARY (System vs Target Config)" RESET "           │\n");
        printf("├───────────┬──────────────────────────────────────────────────────────────────┤\n");
        printf("│ " BOLD "ACTION    " RESET "│ " BOLD "PACKAGE DETAILS" RESET "                                                  │\n");
        printf("├───────────┼──────────────────────────────────────────────────────────────────┤\n");
        for (int i = 0; i < num_add; i++) printf("│ \033[1;32m%-9s\033[0m │ %-64.64s │\n", "[+ INST]", added[i]);
        for (int i = 0; i < num_upg; i++) printf("│ \033[1;36m%-9s\033[0m │ %-64.64s │\n", "[^ UPGR]", upgraded[i]);
        for (int i = 0; i < num_chg; i++) printf("│ \033[1;33m%-9s\033[0m │ %-64.64s │\n", "[~ CHNG]", changed[i]);
        for (int i = 0; i < num_rem; i++) printf("│ \033[1;31m%-9s\033[0m │ %-64.64s │\n", "[- REMV]", removed[i]);
        printf("└───────────┴──────────────────────────────────────────────────────────────────┘\n");
        printf(" Total pending package operations: " BOLD "%d" RESET "\n", total);
      } else if (strcmp(cfg->summary_style, "list") == 0) {
        printf(CYAN "  Pending Package Operations (%d total):" RESET "\n", total);
        for (int i = 0; i < num_add; i++) printf("    • " GREEN "[ADDED]" RESET " %s\n", added[i]);
        for (int i = 0; i < num_upg; i++) printf("    • " CYAN "[UPGRADED]" RESET " %s\n", upgraded[i]);
        for (int i = 0; i < num_chg; i++) printf("    • " YELLOW "[CHANGED]" RESET " %s\n", changed[i]);
        for (int i = 0; i < num_rem; i++) printf("    • " RED "[REMOVED]" RESET " %s\n", removed[i]);
      } else { /* zypper / traditional */
        printf(BOLD "Proposed Package Changes:" RESET "\n");
        if (num_add > 0) {
          printf("\n" GREEN "The following %d NEW package(s) will be INSTALLED:" RESET "\n", num_add);
          for (int i = 0; i < num_add; i++) printf("  " GREEN "+" RESET " %s\n", added[i]);
        }
        if (num_upg > 0) {
          printf("\n" CYAN "The following %d package(s) will be UPGRADED:" RESET "\n", num_upg);
          for (int i = 0; i < num_upg; i++) printf("  " CYAN "^" RESET " %s\n", upgraded[i]);
        }
        if (num_chg > 0) {
          printf("\n" YELLOW "The following %d package(s) will be CHANGED/DOWNGRADED:" RESET "\n", num_chg);
          for (int i = 0; i < num_chg; i++) printf("  " YELLOW "~" RESET " %s\n", changed[i]);
        }
        if (num_rem > 0) {
          printf("\n" RED "The following %d package(s) will be REMOVED:" RESET "\n", num_rem);
          for (int i = 0; i < num_rem; i++) printf("  " RED "-" RESET " %s\n", removed[i]);
        }
        printf("\n" BOLD "Summary:" RESET " %d to install, %d to upgrade, %d changed, %d to remove.\n",
          num_add, num_upg, num_chg, num_rem);
      }
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
        system("command -v gpg-connect-agent >/dev/null 2>&1 && gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1 || true");
      }

      int do_git = 1;
      char rebuild_args[2048] = {0};

      for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--no-git") == 0) {
          do_git = 0;
        } else if (strcmp(argv[i], "--upgrade") == 0) {
          char msg[512];
          snprintf(msg, sizeof(msg), "Updating flake inputs for " CYAN "%s" RESET "...", hostname);
          info(msg);

          struct stat st;
          if (stat(host_lock, &st) == 0) {
            system("cp hosts/\"$(hostname)\"/flake.lock flake.lock 2>/dev/null || true");
          } else if (stat("flake.lock", &st) == 0) {
            snprintf(msg, sizeof(msg), "cp flake.lock %s", host_lock);
            system(msg);
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
          system(msg);
          snprintf(msg, sizeof(msg), "Flake inputs successfully updated and locked for %s.", hostname);
          success(msg);
          return 0;
        } else if (strcmp(argv[i], "--nixonator-update") == 0) {
          info("Self-updating Nixonator module from remote repository...");
          mkdir("modules/nixonator", 0755);
          char curl_cmd[1024];
          snprintf(curl_cmd, sizeof(curl_cmd), "%s -sSL \"https://raw.githubusercontent.com/usr40k/nixonator/main/modules/nixonator/nixonator.nix\" -o modules/nixonator/nixonator.nix", PATH_CURL);
          if (system(curl_cmd) == 0) {
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
            system("rm -rf .git hosts modules flake.nix flake.lock nixonator.conf 2>/dev/null || true");

            if (reclone) {
              char clone_cmd[1024];
              snprintf(clone_cmd, sizeof(clone_cmd), "%s clone \"%s\" .", PATH_GIT, cfg.repo_url);
              info("Re-cloning repository...");
              system(clone_cmd);
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
        system(cp_cmd);
      } else if (stat("flake.lock", &st_lock) == 0) {
        char cp_cmd[512];
        snprintf(cp_cmd, sizeof(cp_cmd), "cp flake.lock \"%s\" 2>/dev/null || true", host_lock);
        system(cp_cmd);
      }

      if (do_git) {
        struct stat st_git;
        if (stat(".git", &st_git) != 0) {
          char git_init[1024];
          snprintf(git_init, sizeof(git_init), "%s init && %s remote add origin \"%s\" && %s branch -M \"%s\"",
            PATH_GIT, PATH_GIT, cfg.repo_url, PATH_GIT, cfg.git_branch);
          system(git_init);
        }

        if (strlen(cfg.git_user_name) > 0) {
          char gcmd[512]; snprintf(gcmd, sizeof(gcmd), "%s config user.name \"%s\"", PATH_GIT, cfg.git_user_name); system(gcmd);
        }
        if (strlen(cfg.git_user_email) > 0) {
          char gcmd[512]; snprintf(gcmd, sizeof(gcmd), "%s config user.email \"%s\"", PATH_GIT, cfg.git_user_email); system(gcmd);
        }
        if (strlen(cfg.gpg_signing_key) > 0) {
          char gcmd[512];
          snprintf(gcmd, sizeof(gcmd), "%s config user.signingkey \"%s\" && %s config commit.gpgsign true", PATH_GIT, cfg.gpg_signing_key, PATH_GIT);
          system(gcmd);
        }

        int stashed = 0;
        if (system(PATH_GIT " diff-index --quiet HEAD -- 2>/dev/null") != 0) {
          info("Stashing local uncommitted changes...");
          system(PATH_GIT " stash push -m \"Nixonator auto-stash\" >/dev/null 2>&1");
          stashed = 1;
        }

        char fetch_cmd[512];
        snprintf(fetch_cmd, sizeof(fetch_cmd), "%s fetch origin \"%s\" || true", PATH_GIT, cfg.git_branch);
        system(fetch_cmd);

        char merge_cmd[512];
        snprintf(merge_cmd, sizeof(merge_cmd), "%s rev-parse --verify origin/\"%s\" >/dev/null 2>&1 && %s merge origin/\"%s\" --no-edit >/dev/null 2>&1 || true",
          PATH_GIT, cfg.git_branch, PATH_GIT, cfg.git_branch);
        system(merge_cmd);

        if (stashed) {
          system(PATH_GIT " stash pop >/dev/null 2>&1 || true");
        }

        /* Flag untracked files (intent-to-add) so Nix Flakes can evaluate them */
        system(PATH_GIT " add -N . >/dev/null 2>&1 || true");
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

      if (strcmp(cfg.pre_install_summary, "true") == 0) {
        info("Silently evaluating target flake profile...");
        printf(CYAN "──────────────────────────────────────────────────────────────────────────────" RESET "\n");
        printf(CYAN "Nixonator: Pre-Rebuild Summary" RESET "\n");

        struct stat st_git;
        if (stat(".git", &st_git) == 0) {
          char count_buf[64] = {0};
          snprintf(gen_cmd, sizeof(gen_cmd), "%s status --porcelain 2>/dev/null | wc -l", PATH_GIT);
          exec_cmd_captured(gen_cmd, count_buf, sizeof(count_buf));
          int pending = atoi(trim(count_buf));
          if (pending > 0) {
            printf("  Local uncommitted file(s): %d\n", pending);
            snprintf(gen_cmd, sizeof(gen_cmd), "%s status --short 2>/dev/null | sed 's/^/    /'", PATH_GIT);
            system(gen_cmd);
            printf("\n");
          }
        }
        /* format_package_summary(config_dir, hostname, &cfg); */
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
        system(gc_wipe);

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
          system(gc_del);
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
        system(PATH_GIT " add -u");

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
            system(add_cmd);
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
                    system(add_cmd);
                  } else if (uans[0] == 'a' || uans[0] == 'A') {
                    char add_cmd[512];
                    snprintf(add_cmd, sizeof(add_cmd), "%s add \"%s\"", PATH_GIT, file);
                    system(add_cmd);
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

        if (system(PATH_GIT " diff --cached --quiet 2>/dev/null") != 0) {
            info("Committing configuration changes...");
        
            // 1. Capture the staged file diff dynamically so it can go into the commit message
            size_t file_buffer_size = 4096;
            char *file_diff = malloc(file_buffer_size);
            if (file_diff != NULL) {
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
        
            // 2. Build the commit message including both your original package logic AND file_diff
            char commit_msg_cmd[8192];
            snprintf(commit_msg_cmd, sizeof(commit_msg_cmd),
                "%s commit -m \"NixOS System Update: %s - %s\n\n### System Metadata\n- Hostname: %s\n- Timestamp: %s\n\n### Generation Shift\n- Previous: %s\n- Current: %s\n\n### Package Changes\n%s\n\n### File Changes\n%s\" >/dev/null 2>&1",
                PATH_GIT, hostname, timestamp, hostname, timestamp, prev_gen_info, new_gen_info, package_diff, file_diff);
        
            // 3. Execute the commit
            system(commit_msg_cmd);
        
            // 4. Pretty git summary block (prints to stdout and matches old style)
            if (strcmp(cfg.pretty_git_summary, "true") == 0) {
                printf(CYAN "────────────────────────────────────────────" RESET "\n");
                printf(CYAN "Nixonator: git summary" RESET "\n");
                
                // Print the file diff to stdout (just like your old system() call did)
                if (file_diff[0] != '\0') {
                    fputs(file_diff, stdout);
                } else {
                    // Fallback to running git show if file_diff wasn't captured
                    system(PATH_GIT " show --stat --format=\"  Commit: %h\" HEAD 2>/dev/null || true");
                }
                
                printf(CYAN "────────────────────────────────────────────" RESET "\n");
            }
        
            // 5. Clean up allocated memory for file_diff
            if (file_diff[0] != '\0') {
                free(file_diff);
            }
        
        } else {
            info("No configuration file changes to commit.");
        }
        
        info("Pushing changes to GitHub...");
        char push_cmd[512];
        snprintf(push_cmd, sizeof(push_cmd), "%s push origin \"%s\" || true", PATH_GIT, cfg.git_branch);
        if (system(push_cmd) != 0) {
            warn("Failed to push to remote repository.");
        }
      } else {
        unlink("flake.lock");
      }

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
