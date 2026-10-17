---
- name: Corona server package update
  hosts: service
  gather_facts: false

  vars_files:
    - "../vars/corona.vars"
    - "../env/{{ ENVNAME }}/{{ ENVNAME }}.vars"

  vars:
    corona_server_root: 'C:\Program Files\CoronaCS\7.9'
    corona_server_target: 'C:\Program Files\CoronaCS\7.9\ora'
    corona_batch_root: 'D:\Corona Start and Stop All Services'
    corona_stop_batch: 'D:\Corona Start and Stop All Services\StopCorona_AllServices.bat'
    corona_start_batch: 'D:\Corona Start and Stop All Services\StartCorona_AllServices.bat'
    extraction_folder: "{{ server_download_path }}\\vendor_extract_temp"

  tasks:
    - name: Validate required inputs
      fail:
        msg: "ENVNAME, package_name and server_download_path must be provided."
      when: >
        ENVNAME is not defined or ENVNAME | string | trim == '' or
        package_name is not defined or package_name | string | trim == '' or
        server_download_path is not defined or server_download_path | string | trim == ''

    - name: Validate package extension
      fail:
        msg: "Package {{ package_name }} must have a .zip extension."
      when: not (package_name | lower | regex_search('\.zip$'))

    - name: Check connectivity
      win_ping:

    - name: Check current remote user
      win_shell: whoami
      register: current_user
      changed_when: false

    - name: Display current remote user
      debug:
        msg: "Connected as {{ current_user.stdout | trim }}"

    - name: Check required paths and files
      win_shell: |
        $ErrorActionPreference = "Stop"

        $requiredItems = @(
          "{{ corona_server_target }}",
          "{{ corona_stop_batch }}",
          "{{ corona_start_batch }}",
          "{{ server_download_path }}\{{ package_name }}"
        )

        $missing = @()
        foreach ($item in $requiredItems) {
          if (-not (Test-Path -LiteralPath $item)) {
            $missing += $item
          }
        }

        if ($missing.Count -gt 0) {
          throw "Required path/file missing: $($missing -join ', ')"
        }

        Write-Output "All required paths and files exist."
      register: precheck_result
      changed_when: false

    - name: Initialise deployment status
      set_fact:
        deployment_summary: []
        deployment_failed: false
        deployment_failure_message: ""
        services_stopped: false

    - name: Run Corona server package update
      block:
        - name: Stop all Corona services
          win_shell: |
            $ErrorActionPreference = "Stop"
            & "{{ corona_stop_batch }}"
            if ($LASTEXITCODE -ne 0) {
              throw "Stop batch returned exit code $LASTEXITCODE"
            }
          register: stop_output

        - name: Display stop output
          debug:
            var: stop_output.stdout_lines

        - name: Mark services as stopped
          set_fact:
            services_stopped: true
            deployment_summary: "{{ deployment_summary + ['Corona services stopped successfully'] }}"

        - name: Get current date for backup naming
          win_shell: |
            Get-Date -Format "ddMMyyyy"
          register: current_date
          changed_when: false

        - name: Find next available backup path
          win_shell: |
            $ErrorActionPreference = "Stop"

            $parentPath = "{{ corona_server_root }}"
            $baseName = "ora_Bkp{{ current_date.stdout | trim }}"
            $candidate = Join-Path -Path $parentPath -ChildPath $baseName
            $suffix = 1

            while (Test-Path -LiteralPath $candidate) {
              $candidate = Join-Path -Path $parentPath -ChildPath ($baseName + "_" + $suffix)
              $suffix++
            }

            Write-Output $candidate
          register: backup_path_result
          changed_when: false

        - name: Set backup path facts
          set_fact:
            backup_full_path: "{{ backup_path_result.stdout | trim }}"
            final_backup_name: "{{ (backup_path_result.stdout | trim).split('\\')[-1] }}"

        - name: Back up existing ora folder
          win_shell: |
            $ErrorActionPreference = "Stop"

            $sourceFolder = "{{ corona_server_target }}"
            $destinationFolder = "{{ backup_full_path }}"

            if (-not (Test-Path -LiteralPath $sourceFolder -PathType Container)) {
              throw "Source folder not found: $sourceFolder"
            }

            Copy-Item -LiteralPath $sourceFolder `
                      -Destination $destinationFolder `
                      -Recurse `
                      -Force `
                      -ErrorAction Stop

            if (-not (Test-Path -LiteralPath $destinationFolder -PathType Container)) {
              throw "Backup folder was not created: $destinationFolder"
            }

            $sourceCount = @(Get-ChildItem -LiteralPath $sourceFolder -Recurse -File).Count
            $backupCount = @(Get-ChildItem -LiteralPath $destinationFolder -Recurse -File).Count

            if ($sourceCount -ne $backupCount) {
              throw "Backup verification failed. Source files: $sourceCount; backup files: $backupCount"
            }

            Write-Output "Backup created: $destinationFolder"
            Write-Output "Backup file count: $backupCount"
          register: backup_result

        - name: Display backup result
          debug:
            var: backup_result.stdout_lines

        - name: Add backup result to summary
          set_fact:
            deployment_summary: "{{ deployment_summary + ['Backup created: ' + final_backup_name] }}"

        - name: Remove any old temporary extraction folder
          win_file:
            path: "{{ extraction_folder }}"
            state: absent

        - name: Create temporary extraction folder
          win_file:
            path: "{{ extraction_folder }}"
            state: directory

        - name: Extract vendor package
          win_shell: |
            $ErrorActionPreference = "Stop"

            $zipFile = "{{ server_download_path }}\{{ package_name }}"
            $extractPath = "{{ extraction_folder }}"

            Expand-Archive -LiteralPath $zipFile `
                           -DestinationPath $extractPath `
                           -Force `
                           -ErrorAction Stop

            Write-Output "Package extracted successfully to: $extractPath"
          register: extract_result

        - name: Check extracted Server folder
          win_stat:
            path: "{{ extraction_folder }}\\Server"
          register: server_folder_status

        - name: Fail when extracted Server folder is missing
          fail:
            msg: "Server folder was not found inside {{ package_name }}."
          when: >
            not server_folder_status.stat.exists or
            not server_folder_status.stat.isdir

        - name: Count files in vendor Server folder
          win_shell: |
            $count = @(Get-ChildItem -LiteralPath "{{ extraction_folder }}\Server" -Recurse -File).Count
            Write-Output $count
          register: vendor_file_count
          changed_when: false

        - name: Fail when vendor Server folder contains no files
          fail:
            msg: "The extracted Server folder contains no files."
          when: (vendor_file_count.stdout | trim | int) == 0

        - name: Copy vendor Server files to Corona ora folder
          win_shell: |
            $ErrorActionPreference = "Stop"

            $sourceFolder = "{{ extraction_folder }}\Server"
            $destinationFolder = "{{ corona_server_target }}"
            $copiedCount = 0

            Get-ChildItem -LiteralPath $sourceFolder -Recurse | ForEach-Object {
              $relativePath = $_.FullName.Substring($sourceFolder.Length).TrimStart('\')
              $destinationPath = Join-Path -Path $destinationFolder -ChildPath $relativePath

              if ($_.PSIsContainer) {
                if (-not (Test-Path -LiteralPath $destinationPath)) {
                  New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
                }
              }
              else {
                $parentFolder = Split-Path -Path $destinationPath -Parent

                if (-not (Test-Path -LiteralPath $parentFolder)) {
                  New-Item -ItemType Directory -Path $parentFolder -Force | Out-Null
                }

                Copy-Item -LiteralPath $_.FullName `
                          -Destination $destinationPath `
                          -Force `
                          -ErrorAction Stop
                $copiedCount++
              }
            }

            Write-Output $copiedCount
          register: copied_file_count

        - name: Verify every deployed vendor file
          win_shell: |
            $ErrorActionPreference = "Stop"

            $sourceFolder = "{{ extraction_folder }}\Server"
            $destinationFolder = "{{ corona_server_target }}"
            $verifiedCount = 0
            $failedFiles = @()

            Get-ChildItem -LiteralPath $sourceFolder -Recurse -File | ForEach-Object {
              $relativePath = $_.FullName.Substring($sourceFolder.Length).TrimStart('\')
              $destinationPath = Join-Path -Path $destinationFolder -ChildPath $relativePath

              if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
                $failedFiles += "$relativePath (missing)"
              }
              else {
                $destinationFile = Get-Item -LiteralPath $destinationPath

                if ($destinationFile.Length -ne $_.Length) {
                  $failedFiles += "$relativePath (size mismatch)"
                }
                else {
                  $verifiedCount++
                }
              }
            }

            if ($failedFiles.Count -gt 0) {
              throw "Deployment verification failed for: $($failedFiles -join '; ')"
            }

            Write-Output $verifiedCount
          register: verified_file_count
          changed_when: false

        - name: Validate deployment file counts
          fail:
            msg: >
              File count mismatch. Vendor={{ vendor_file_count.stdout | trim }},
              copied={{ copied_file_count.stdout | trim }},
              verified={{ verified_file_count.stdout | trim }}.
          when: >
            (vendor_file_count.stdout | trim | int) != (copied_file_count.stdout | trim | int) or
            (vendor_file_count.stdout | trim | int) != (verified_file_count.stdout | trim | int)

        - name: Unblock only files deployed from this package
          win_shell: |
            $ErrorActionPreference = "Stop"

            $sourceFolder = "{{ extraction_folder }}\Server"
            $destinationFolder = "{{ corona_server_target }}"
            $unblockedCount = 0

            Get-ChildItem -LiteralPath $sourceFolder -Recurse -File | ForEach-Object {
              $relativePath = $_.FullName.Substring($sourceFolder.Length).TrimStart('\')
              $destinationPath = Join-Path -Path $destinationFolder -ChildPath $relativePath

              if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
                Unblock-File -LiteralPath $destinationPath -ErrorAction Stop
                $unblockedCount++
              }
            }

            Write-Output $unblockedCount
          register: unblock_count

        - name: Add deployment results to summary
          set_fact:
            deployment_summary: "{{ deployment_summary + [
              'Vendor Server files: ' + (vendor_file_count.stdout | trim),
              'Files copied: ' + (copied_file_count.stdout | trim),
              'Files verified: ' + (verified_file_count.stdout | trim),
              'Files unblocked: ' + (unblock_count.stdout | trim)
            ] }}"

      rescue:
        - name: Capture deployment failure
          set_fact:
            deployment_failed: true
            deployment_failure_message: >-
              {{
                ansible_failed_result.msg
                | default(ansible_failed_result.stderr
                | default(ansible_failed_result.stdout
                | default('Unknown deployment failure')))
              }}

        - name: Display deployment failure
          debug:
            msg: "Corona server package update failed: {{ deployment_failure_message }}"

      always:
        - name: Remove temporary extraction folder
          win_file:
            path: "{{ extraction_folder }}"
            state: absent

        - name: Start all Corona services
          win_shell: |
            $ErrorActionPreference = "Stop"
            & "{{ corona_start_batch }}"
            if ($LASTEXITCODE -ne 0) {
              throw "Start batch returned exit code $LASTEXITCODE"
            }
          register: start_output
          when: services_stopped | bool

        - name: Display start output
          debug:
            var: start_output.stdout_lines
          when:
            - services_stopped | bool
            - start_output is defined

        - name: Add service start result to summary
          set_fact:
            deployment_summary: "{{ deployment_summary + ['Corona services started successfully'] }}"
          when:
            - services_stopped | bool
            - start_output is defined
            - start_output.rc == 0

    - name: Fail the job after cleanup and service recovery
      fail:
        msg: "Corona server package update failed: {{ deployment_failure_message }}"
      when: deployment_failed | bool

    - name: Generate deployment timestamp
      win_shell: |
        Get-Date -Format "yyyy-MM-dd HH:mm:ss"
      register: deployment_timestamp
      changed_when: false

    - name: Create final deployment summary
      set_fact:
        final_summary: |
          ============================================================
          CORONA SERVER PACKAGE UPDATE - DEPLOYMENT SUMMARY
          ============================================================
          Environment     : {{ ENVNAME }}
          Package         : {{ package_name }}
          Backup name     : {{ final_backup_name }}
          Backup location : {{ backup_full_path }}
          Deployment date : {{ deployment_timestamp.stdout | trim }}

          Deployment steps:
          {{ deployment_summary | join('\n') }}

          File verification:
          Vendor files    : {{ vendor_file_count.stdout | trim }}
          Copied files    : {{ copied_file_count.stdout | trim }}
          Verified files  : {{ verified_file_count.stdout | trim }}
          Unblocked files : {{ unblock_count.stdout | trim }}

          Status           : DEPLOYMENT COMPLETED SUCCESSFULLY
          ============================================================

    - name: Print deployment summary
      debug:
        msg: "{{ final_summary }}"

    - name: Create log filename timestamp
      win_shell: |
        Get-Date -Format "yyyyMMdd_HHmmss"
      register: log_timestamp
      changed_when: false

    - name: Save deployment summary to file
      win_copy:
        content: "{{ final_summary }}"
        dest: "{{ server_download_path }}\\CORONA_ServerPackageUpdate_{{ log_timestamp.stdout | trim }}.log"
      register: summary_file

    - name: Display summary file location
      debug:
        msg: "Deployment summary saved to {{ summary_file.dest }}"
