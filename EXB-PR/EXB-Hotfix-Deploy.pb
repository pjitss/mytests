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
          The package may not have been created by EXB-Hotfix-Build - manifest is required for deployment.
      when: not manifest_stat.stat.exists
      tags:
        - verify

    - name: read changed files from manifest
      slurp:
        src: "{{ precheck_dir }}/{{ artifact_name }}.manifest"
      register: manifest_raw
      tags:
        - verify

    - name: set changed_file_list from manifest
      set_fact:
        changed_file_list: >-
          {{
            (manifest_raw.content | b64decode).splitlines()
            | map('trim')
            | select('match', '.+')
            | list
          }}
      tags:
        - verify

    - name: validate file list contains file paths not directory paths
      fail:
        msg: >
          SAFETY ABORT: '{{ item }}' looks like a top-level directory, not a file path.
          Hotfix deployments must list individual files. Rebuild with EXB-Hotfix-Build.
      loop: "{{ changed_file_list }}"
      when: item.split('/') | length <= 1
      tags:
        - verify

    - name: show package and file list
      debug:
        msg:
          - "Package   : {{ artifact_name }}"
          - "Files     : {{ changed_file_list | length }}"
          - "File list : {{ changed_file_list }}"
      tags:
        - verify

    ## ---------------- UPLOAD ----------------

    - name: upload hotfix archive to Nexus
      shell: |
        curl -v -k -u {{ nexus_username }}:'{{ nexus_password }}' \
          --upload-file {{ precheck_dir }}/{{ artifact_name }} \
          {{ nexus_url }}/{{ artifact_name }}
      args:
        executable: /bin/bash
      register: upload_result
      tags:
        - upload

    - name: upload summary
      debug:
        msg: "Successfully uploaded {{ artifact_name }} to Nexus: {{ nexus_url }}/{{ artifact_name }}"
      tags:
        - upload

    ## ---------------- DEPLOY ----------------

    - name: set changed_file_list from manifest (deploy tag re-reads manifest)
      block:
        - name: read manifest for deploy
          slurp:
            src: "{{ precheck_dir }}/{{ artifact_name }}.manifest"
          register: manifest_raw_deploy

        - name: set fact from manifest
          set_fact:
            changed_file_list: >-
              {{
                (manifest_raw_deploy.content | b64decode).splitlines()
                | map('trim')
                | select('match', '.+')
                | list
              }}
      tags:
        - deploy

    - name: show changed files
      debug:
        var: changed_file_list
      tags:
        - deploy

    - name: create temp download directory
      file:
        path: "{{ temp_download_path }}"
        state: directory
        mode: '0755'
      tags:
        - deploy

    - name: download hotfix package from Nexus
      get_url:
        url: "{{ nexus_url }}/{{ artifact_name }}"
        validate_certs: false
        url_username: "{{ nexus_username }}"
        url_password: "{{ nexus_password }}"
        dest: "{{ temp_download_path }}/{{ artifact_name }}"
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
      ignore_errors: yes
      tags:
        - deploy

    - name: show kill result
      debug:
        msg: "{{ kill_result.stdout }}"
      tags:
        - deploy

    - name: create timestamped backup directory
      file:
        path: "{{ backup_dir_with_timestamp }}"
        state: directory
        mode: '0755'
      tags:
        - deploy

    # This separate directory creation task is retained from the current playbook.
    # It can be removed later because the backup copy task creates parent directories itself.
    - name: backup existing files - create subdirectories
      shell: |
        while IFS= read -r file_path; do
          dir_path="$(dirname "$file_path")"
          if [ -n "$dir_path" ] && [ "$dir_path" != "." ]; then
            mkdir -p "{{ backup_dir_with_timestamp }}/$dir_path"
          fi
        done <<'EOF'
        {{ changed_file_list | join('\n') }}
        EOF
      args:
        executable: /bin/bash
      tags:
        - deploy

    - name: backup existing files - copy with directory structure
      shell: |
        src="{{ target_path }}/{{ item }}"
        dest="{{ backup_dir_with_timestamp }}/{{ item }}"

        if [ -d "$src" ]; then
          mkdir -p "$dest"
          cp -rp "$src/." "$dest/"
        elif [ -e "$src" ] || [ -L "$src" ]; then
          mkdir -p "$(dirname "$dest")"
          cp -p "$src" "$dest"
        else
          echo "Backup skipped - source file does not exist: $src"
        fi
      args:
        executable: /bin/bash
      loop: "{{ changed_file_list }}"
      register: backup_result
      tags:
        - deploy

    - name: ensure target directories exist
      file:
        path: "{{ target_path }}/{{ item | dirname }}"
        state: directory
        mode: '0755'
      loop: "{{ changed_file_list }}"
      when: item | dirname != ''
      tags:
        - deploy

    - name: copy updated files from temp location to target host
      shell: |
        src="{{ temp_download_path }}/{{ item }}"
        dest="{{ target_path }}/{{ item }}"

        if [ -d "$src" ]; then
          mkdir -p "$dest"
          cp -rf "$src/." "$dest/"
        else
          mkdir -p "$(dirname "$dest")"
          cp -f "$src" "$dest"
        fi
      args:
        executable: /bin/bash
      loop: "{{ changed_file_list }}"
      register: copy_result
      tags:
        - deploy

    - name: start JBoss
      shell: |
        cd {{ target_path }}/jboss/bin/
        nohup ./standalone.sh > {{ target_path }}/jboss/standalone/log/nohup.out 2>&1 &
      ignore_errors: yes
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
          tail -20 {{ target_path }}/jboss/standalone/log/server.log 2>/dev/null || echo "No server.log found yet"
          echo ""
          echo "JBoss process not found after 45 seconds"
          exit 1
        else
          echo "JBoss Started: $JAVA_INFO"
        fi
      args:
        executable: /bin/bash
      register: java_process
      ignore_errors: yes
      when: jboss_restart_bool
      tags:
        - deploy

    - name: show jboss restart status
      debug:
        var: java_process
      when: jboss_restart_bool
      tags:
        - deploy

    - name: generate deployment summary facts
      set_fact:
        updated_files_with_paths: "{{ copy_result.results | selectattr('changed') | map(attribute='item') | map('regex_replace', '^(.*)$', target_path + '/\\1') | list }}"
        backed_up_files_with_paths: "{{ backup_result.results | selectattr('changed') | map(attribute='item') | map('regex_replace', '^(.*)$', backup_dir_with_timestamp + '/\\1') | list }}"
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
      debug:
        msg:
          - "============================================================"
          - " HOTFIX DEPLOYMENT SUMMARY"
          - "============================================================"
          - " Artifact    : {{ artifact_name }}"
          - " Total Files : {{ changed_file_list | length }}"
          - " Updated     : {{ updated_files_with_paths | length }}"
          - " Target Path : {{ target_path }}"
          - " Backup      : {{ backup_dir_with_timestamp }}"
          - "------------------------------------------------------------"
          - " REPLACED FILES:"
          - "{{ updated_display }}"
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
