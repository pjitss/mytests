- name: Upload/download files to Nexus
  hosts: all
  gather_facts: no
  vars_files:
    - ../../vars/common.var

  tasks:

    - name: Detect package type for each file
      set_fact:
        pkg_type_map: >-
          {{
            (pkg_type_map | default({})) |
            combine({
              item: (
                'OFAC' if 'OFAC' in item else
                'FOF64' if 'FOF64' in item else
                'FILTER_CONFIG' if 'FILTER_CONFIG' in item else
                'FILTER_UPDATE' if 'FILTER_UPDATE' in item else
                'UNKNOWN'
              )
            })
          }}
      loop: "{{ file_name.split(',') }}"

    - name: Build Nexus path for each file
      set_fact:
        nexus_path_map: >-
          {{
            (nexus_path_map | default({})) |
            combine({
              item: (
                package_type_nexus_paths[pkg_type_map[item]] | default('') | trim
              )
            })
          }}
      loop: "{{ file_name.split(',') }}"

    - name: Print file-to-Nexus-path map
      debug:
        msg: "File '{{ item }}' will upload to Nexus dir '{{ nexus_path_map[item] }}'"
      loop: "{{ file_name.split(',') }}"

    - name: Check if file already exists in Nexus (per directory)
      shell: |
        curl -s -o /dev/null -w "%{http_code}" -u admin:redhat {{ nexus_path_map[item] }}{{ item | trim }}
      register: file_check
      loop: "{{ file_name.split(',') }}"
      loop_control:
        label: "{{ item }}"

    - name: Debug file existence HTTP code
      debug:
        msg: "File check for {{ item }} returned HTTP code {{ file_check.results[loop.index0].stdout }}"
      loop: "{{ file_name.split(',') }}"
      loop_control:
        label: "{{ item }}"

    - name: Fail if file already exists
      fail:
        msg: "File {{ item }} already exists in Nexus. Upload forbidden to prevent overwriting."
      when: file_check.results[loop.index0].stdout == "200"
      loop: "{{ file_name.split(',') }}"
      loop_control:
        label: "{{ item }}"

    - name: Upload each file to its Nexus directory based on file type
      shell: |
        curl -u admin:redhat --upload-file /tmp/{{ item | trim }} {{ nexus_path_map[item] }}{{ item | trim }}
      when: 
        - task == 'Nexus-Upload'
        - file_check.results[loop.index0].stdout == "404"
      loop: "{{ file_name.split(',') }}"
      loop_control:
        label: "{{ item }}"

    - name: Download each file from its Nexus directory
      shell: |
        curl -u admin:redhat -o /tmp/{{ item | trim }} {{ nexus_path_map[item] }}{{ item | trim }}
      when: 
        - task == 'Nexus-Download'
        - file_check.results[loop.index0].stdout == "200"
      loop: "{{ file_name.split(',') }}"
      loop_control:
        label: "{{ item }}"