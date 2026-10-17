---
## Deploy playbook - reads the package from the precheck folder,
## uploads to Nexus, then deploys to target host.
## PACKAGENAME is provided by app team after they verify the precheck folder.

- hosts: test
  become: yes
  become_user: eximadm
  gather_facts: yes
  vars_files:
    - "vars/{{ ENVNAME }}/pr-deploy.var"

  vars:
    precheck_dir: "{{ app_home }}/Hotfix_Deploy_Precheck"
    target_path: "{{ app_home }}"
    backup_path: "{{ app_home }}/backup"
    temp_download_path: "{{ app_home }}/tmppath"
    backup_timestamp: "{{ ansible_date_time.iso8601_basic_short }}"
    backup_dir_with_timestamp: "{{ backup_path }}/{{ backup_timestamp }}"
    jboss_restart_bool: "{{ jboss_restart | default('true') | bool }}"

  tasks:

    ## ---------------- VERIFY ----------------

    - name: ping connectivity check
      ping:
      tags:
        - verify

    - name: verify package exists in precheck folder
      stat:
        path: "{{ precheck_dir }}/{{ artifact_name }}"
      register: pkg_stat
      tags:
        - verify

    - name: abort if package not found
      fail:
        msg: >
          Package '{{ artifact_name }}' not found in {{ precheck_dir }}/.
          Run EXB-Hotfix-Build first, or check the PACKAGENAME parameter.
      when: not pkg_stat.stat.exists
      tags:
        - verify

    - name: verify manifest sidecar exists
      stat:
        path: "{{ precheck_dir }}/{{ artifact_name }}.manifest"
      register: manifest_stat
      tags:
        - verify

    - name: abort if manifest not found
      fail:
        msg: >
          Manifest '{{ artifact_name }}.manifest' not found in {{ precheck_dir }}/.
          The package may not have been created by EXB-Hotfix-Build.
      when: not manifest_stat.stat.exists
      tags:
        - verify

    - name: verify deleted-files sidecar exists                    # ###changed line
      stat:                                                        # ###changed line
        path: "{{ precheck_dir }}/{{ artifact_name }}.deleted"     # ###changed line
      register: deleted_stat                                      # ###changed line
      tags:                                                       # ###changed line
        - verify                                                  # ###changed line

    - name: abort if deleted-files sidecar not found               # ###changed line
      fail:                                                        # ###changed line
        msg: >                                                    # ###changed line
          Deleted-files sidecar '{{ artifact_name }}.deleted' was not found in
          {{ precheck_dir }}/. Rebuild the package using the updated build job.
      when: not deleted_stat.stat.exists                           # ###changed line
      tags:                                                       # ###changed line
        - verify                                                  # ###changed line

    - name: read changed files from manifest
      slurp:
        src: "{{ precheck_dir }}/{{ artifact_name }}.manifest"
      register: manifest_raw
      tags:
        - verify

    - name: read deleted files from sidecar                        # ###changed line
      slurp:                                                       # ###changed line
        src: "{{ precheck_dir }}/{{ artifact_name }}.deleted"      # ###changed line
      register: deleted_raw                                       # ###changed line
      tags:                                                       # ###changed line
        - verify                                                  # ###changed line

    - name: set changed and deleted file lists                     # ###changed line
      set_fact:
        changed_file_list: >-
          {{
            (manifest_raw.content | b64decode).splitlines()
            | map('trim')
            | select('match', '.+')
            | list
          }}
        deleted_file_list: >-                                     # ###changed line
          {{                                                      
            (deleted_raw.content | b64decode).splitlines()
            | map('trim')
            | select('match', '.+')
            | list
          }}
      tags:
        - verify

    - name: validate manifest paths                                # ###changed line
      shell: |                                                    # ###changed line
        validate_list() {
          list_file="$1"
          label="$2"

          if grep -nEv '^jboss/.+' "$list_file"; then
            echo "SAFETY ABORT: $label contains an invalid path."
            echo "Every non-empty entry must start with jboss/."
            exit 1
          fi

          if grep -nE '(^"|^/|(^|/)\.\.(/|$))' "$list_file"; then
            echo "SAFETY ABORT: $label contains a quoted, absolute, or parent-traversal path."
            exit 1
          fi
        }

        validate_list "{{ precheck_dir }}/{{ artifact_name }}.manifest" "manifest"
        validate_list "{{ precheck_dir }}/{{ artifact_name }}.deleted" "deleted sidecar"
      args:
        executable: /bin/bash
      changed_when: false                                        # ###changed line
      tags:
        - verify

    - name: show package and file counts                           # ###changed line
      debug:
        msg:
          - "Package        : {{ artifact_name }}"
          - "Packaged files : {{ changed_file_list | length }}"
          - "Deleted files  : {{ deleted_file_list | length }}"   # ###changed line
      tags:
        - verify

    ## ---------------- UPLOAD ----------------

    - name: upload hotfix archive to Nexus
      shell: |
        curl --fail --show-error --silent -k \
          -u "{{ nexus_username }}:{{ nexus_password }}" \
          --upload-file "{{ precheck_dir }}/{{ artifact_name }}" \
          "{{ nexus_url }}/{{ artifact_name }}"
      args:
        executable: /bin/bash
      register: upload_result
      no_log: true                                                # ###changed line
      tags:
        - upload

    - name: upload summary
      debug:
        msg: "Successfully uploaded {{ artifact_name }} to Nexus: {{ nexus_url }}/{{ artifact_name }}"
      tags:
        - upload

    ## ---------------- DEPLOY ----------------

    - name: read deployment sidecars                              # ###changed line
      block:
        - name: read manifest for deploy
          slurp:
            src: "{{ precheck_dir }}/{{ artifact_name }}.manifest"
          register: manifest_raw_deploy

        - name: read deleted sidecar for deploy                   # ###changed line
          slurp:                                                  # ###changed line
            src: "{{ precheck_dir }}/{{ artifact_name }}.deleted" # ###changed line
          register: deleted_raw_deploy                            # ###changed line

        - name: set deployment file lists                         # ###changed line
          set_fact:
            changed_file_list: >-
              {{
                (manifest_raw_deploy.content | b64decode).splitlines()
                | map('trim')
                | select('match', '.+')
                | list
              }}
            deleted_file_list: >-                                 # ###changed line
              {{
                (deleted_raw_deploy.content | b64decode).splitlines()
                | map('trim')
                | select('match', '.+')
                | list
              }}
      tags:
        - deploy

    - name: create temp download directory
      file:
        path: "{{ temp_download_path }}"
        state: directory
        mode: '0755'
      tags:
        - deploy

    - name: write changed-file list on target                     # ###changed line
      copy:                                                       # ###changed line
        content: "{{ changed_file_list | join('\n') }}\n"         # ###changed line
        dest: "{{ temp_download_path }}/changed_files.list"       # ###changed line
        mode: '0600'                                              # ###changed line
      tags:
        - deploy

    - name: write deleted-file list on target                     # ###changed line
      copy:                                                       # ###changed line
        content: "{{ deleted_file_list | join('\n') }}\n"         # ###changed line
        dest: "{{ temp_download_path }}/deleted_files.list"       # ###changed line
        mode: '0600'                                              # ###changed line
      tags:
        - deploy

    - name: download hotfix package from Nexus
      get_url:
        url: "{{ nexus_url }}/{{ artifact_name }}"
        validate_certs: false
        url_username: "{{ nexus_username }}"
        url_password: "{{ nexus_password }}"
        dest: "{{ temp_download_path }}/{{ artifact_name }}"
      no_log: true                                                # ###changed line
      tags:
        - deploy

    - name: unzip hotfix archive
      unarchive:
        src: "{{ temp_download_path }}/{{ artifact_name }}"
        dest: "{{ temp_download_path }}/"
        remote_src: yes
      tags:
        - deploy

    - name: stop existing JBoss processes
      shell: |
        PIDS=$(ps -ef | grep -v grep | grep -w java | awk '{print $2}')
        if [ -n "$PIDS" ]; then
          kill -9 $PIDS
          echo "Killed JBoss PIDs: $PIDS"
        else
          echo "No JBoss processes running"
        fi
      register: kill_result
      when: jboss_restart_bool                                    # ###changed line
      tags:
        - deploy

    - name: show kill result
      debug:
        msg: "{{ kill_result.stdout }}"
      when: jboss_restart_bool                                    # ###changed line
      tags:
        - deploy

    - name: create timestamped backup directory
      file:
        path: "{{ backup_dir_with_timestamp }}"
        state: directory
        mode: '0755'
      tags:
        - deploy

    - name: backup existing changed and deleted files in one operation  # ###changed line
      shell: |
        backup_one() {
          relative_path="$1"
          [ -z "$relative_path" ] && return 0

          src="{{ target_path }}/$relative_path"
          dest="{{ backup_dir_with_timestamp }}/$relative_path"

          if [ -d "$src" ]; then
            mkdir -p "$dest"
            cp -rp "$src/." "$dest/"
            echo "BACKED_UP:$relative_path"
          elif [ -e "$src" ] || [ -L "$src" ]; then
            mkdir -p "$(dirname "$dest")"
            cp -p "$src" "$dest"
            echo "BACKED_UP:$relative_path"
          else
            echo "BACKUP_SKIPPED:$relative_path"
          fi
        }

        while IFS= read -r relative_path || [ -n "$relative_path" ]; do
          backup_one "$relative_path"
        done < "{{ temp_download_path }}/changed_files.list"

        while IFS= read -r relative_path || [ -n "$relative_path" ]; do
          backup_one "$relative_path"
        done < "{{ temp_download_path }}/deleted_files.list"
      args:
        executable: /bin/bash
      register: backup_result
      tags:
        - deploy

    - name: copy all packaged files in one operation               # ###changed line
      shell: |
        while IFS= read -r relative_path || [ -n "$relative_path" ]; do
          [ -z "$relative_path" ] && continue

          src="{{ temp_download_path }}/$relative_path"
          dest="{{ target_path }}/$relative_path"

          if [ -d "$src" ]; then
            mkdir -p "$dest"
            cp -rf "$src/." "$dest/"
          elif [ -e "$src" ] || [ -L "$src" ]; then
            mkdir -p "$(dirname "$dest")"
            cp -f "$src" "$dest"
          else
            echo "ERROR: Packaged source does not exist: $src"
            exit 1
          fi

          echo "UPDATED:$relative_path"
        done < "{{ temp_download_path }}/changed_files.list"
      args:
        executable: /bin/bash
      register: copy_result
      tags:
        - deploy

    - name: delete files listed by the build job                   # ###changed line
      shell: |
        while IFS= read -r relative_path || [ -n "$relative_path" ]; do
          [ -z "$relative_path" ] && continue

          target="{{ target_path }}/$relative_path"

          if [ -e "$target" ] || [ -L "$target" ]; then
            rm -rf -- "$target"
            echo "DELETED:$relative_path"
          else
            echo "DELETE_SKIPPED:$relative_path"
          fi
        done < "{{ temp_download_path }}/deleted_files.list"
      args:
        executable: /bin/bash
      register: delete_result
      tags:
        - deploy

    - name: start JBoss
      shell: |
        cd "{{ target_path }}/jboss/bin/"
        nohup ./standalone.sh > "{{ target_path }}/jboss/standalone/log/nohup.out" 2>&1 &
      when: jboss_restart_bool
      tags:
        - deploy

    - name: wait for JBoss to start
      pause:
        seconds: 45
      when: jboss_restart_bool
      tags:
        - deploy

    - name: verify java process is running
      shell: |
        JAVA_INFO=$(ps -ef | grep -v grep | grep java | head -1 | awk '{print "PID=" $2 " User=" $1}')
        if [ -z "$JAVA_INFO" ]; then
          echo "Checking JBoss logs..."
          tail -20 "{{ target_path }}/jboss/standalone/log/server.log" 2>/dev/null || echo "No server.log found yet"
          echo "JBoss process not found after 45 seconds"
          exit 1
        else
          echo "JBoss Started: $JAVA_INFO"
        fi
      args:
        executable: /bin/bash
      register: java_process
      when: jboss_restart_bool
      tags:
        - deploy

    - name: show JBoss restart status
      debug:
        var: java_process
      when: jboss_restart_bool
      tags:
        - deploy

    - name: generate deployment summary facts                     # ###changed line
      set_fact:
        updated_files_with_paths: >-
          {{
            copy_result.stdout_lines
            | select('match', '^UPDATED:')
            | map('regex_replace', '^UPDATED:', target_path + '/')
            | list
          }}
        backed_up_files_with_paths: >-
          {{
            backup_result.stdout_lines
            | select('match', '^BACKED_UP:')
            | map('regex_replace', '^BACKED_UP:', backup_dir_with_timestamp + '/')
            | list
          }}
        deleted_files_with_paths: >-                              # ###changed line
          {{
            delete_result.stdout_lines
            | select('match', '^DELETED:')
            | map('regex_replace', '^DELETED:', target_path + '/')
            | list
          }}
      tags:
        - deploy

    - name: deployment summary
      vars:
        summary_threshold: 30
        updated_display: >-
          {% if updated_files_with_paths | length > summary_threshold %}
          {{ updated_files_with_paths | length }} files updated. See {{ backup_dir_with_timestamp }} for details.
          {% else %}
          {{ updated_files_with_paths | to_nice_yaml }}
          {% endif %}
        backed_display: >-
          {% if backed_up_files_with_paths | length > summary_threshold %}
          {{ backed_up_files_with_paths | length }} files backed up. See {{ backup_dir_with_timestamp }}.
          {% else %}
          {{ backed_up_files_with_paths | to_nice_yaml }}
          {% endif %}
        deleted_display: >-                                      # ###changed line
          {% if deleted_files_with_paths | length > summary_threshold %}
          {{ deleted_files_with_paths | length }} files deleted.
          {% else %}
          {{ deleted_files_with_paths | to_nice_yaml }}
          {% endif %}
      debug:
        msg:
          - "============================================================"
          - " HOTFIX DEPLOYMENT SUMMARY"
          - "============================================================"
          - " Artifact       : {{ artifact_name }}"
          - " Packaged Files : {{ changed_file_list | length }}"
          - " Deleted Files  : {{ deleted_file_list | length }}"
          - " Updated        : {{ updated_files_with_paths | length }}"
          - " Removed        : {{ deleted_files_with_paths | length }}"
          - " Target Path    : {{ target_path }}"
          - " Backup         : {{ backup_dir_with_timestamp }}"
          - "------------------------------------------------------------"
          - " UPDATED FILES:"
          - "{{ updated_display }}"
          - "------------------------------------------------------------"
          - " DELETED FILES:"
          - "{{ deleted_display }}"
          - "------------------------------------------------------------"
          - " BACKED UP FILES:"
          - "{{ backed_display }}"
          - "============================================================"
      tags:
        - deploy

    - name: cleanup temp download directory
      file:
        path: "{{ temp_download_path }}"
        state: absent
      tags:
        - deploy
