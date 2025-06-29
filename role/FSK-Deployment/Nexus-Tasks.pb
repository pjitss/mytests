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

    # >>>>> From here onward, always loop over file_check.results <<<<<

    - name: Debug file existence HTTP code
      debug:
        msg: "File check for {{ item.item }} returned HTTP code {{ item.stdout }}"
      loop: "{{ file_check.results }}"

    - name: Fail if file already exists
      fail:
        msg: "File {{ item.item }} already exists in Nexus. Upload forbidden to prevent overwriting."
      when: item.stdout == "200"
      loop: "{{ file_check.results }}"

    - name: Upload each file to its Nexus directory based on file type
      shell: |
        curl -u admin:redhat --upload-file {{ upload_source_path_lin }}/{{ item.item | trim }} {{ nexus_path_map[item.item | default(item)] }}{{ item.item | trim }}
      when: 
        - task == 'Nexus-Upload'
        - item.stdout == "404"
      loop: "{{ file_check.results }}"

    - name: Download each file from its Nexus directory
      shell: |
        curl -u admin:redhat -o /tmp/{{ item.item | trim }} {{ nexus_path_map[item.item] }}{{ item.item | trim }}
      when: 
        - task == 'Nexus-Download'
        - item.stdout == "200"
      loop: "{{ file_check.results }}"