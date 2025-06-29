---
- name: Run Oracle SQL script on Windows server
  hosts: oracle_windows
  gather_facts: no
  vars_files:
    - "../vars/common.var"
  tasks:

    - name: Split SQL filenames
      set_fact:
        sql_files: "{{ file_names.split(',') }}"

    - name: Remove old SQL files from script directory
      win_file:
        path: '{{ script_path }}'
        state: absent

    - name: Re-create the script directory
      win_file:
        path: '{{ script_path }}'
        state: directory

    - name: Copy all SQL files to the DB host
      copy:
        src: "files/sql/{{ item | trim }}"
        dest: "{{ script_path }}\\{{ item | trim }}"
      loop: "{{ sql_files }}"

    - name: "Copy sql script files to DB host inside master.sql"
      template:
        src: master.sql.j2
        dest: "{{ script_path }}\\master.sql"

    - name: "Build master.sql from parameters"
      template:
        src: master.sql.j2
        dest: "{{ script_path }}\\master.sql"

    - name: Test Oracle connection before running main script
      win_shell: |
        echo "SELECT 1 FROM dual;" | sqlplus -s {{ db_username }}/{{ db_password }}@{{ db_host }}:{{ db_port }}/{{ db_svc }}
      register: test_conn

    - name: Fail if DB connection test fails
      fail:
        msg: "Database connection failed: {{ test_conn.stdout }}"
      when: "'ORA-' in test_conn.stdout or 'ERROR' in test_conn.stdout"

    - name: Run SQL*Plus with script
      win_shell: |
        sqlplus {{ db_username }}/{{ db_password }}@{{ db_host }}:{{ db_port }}/{{ db_svc }} @{{ script_path }}\{{ main_sql }}
      register: sqlplus_output

    - name: Show output
      debug:
        var: sqlplus_output.stdout
