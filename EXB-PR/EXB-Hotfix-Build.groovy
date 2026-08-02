import groovy.json.*

def GHE_API_BASE = "https://github.jitsocp.com/api/v3"
def GHE_ORG      = "Eximbills"
def GHE_REPO     = "TradeFinanceEE"
def GHE_CRED_ID  = "cicd-TradeFinanceEE"

node("${ENV}") {
    cleanWs()

    def workspacePath       = env.WORKSPACE
    def HOTFIX_ARTIFACT_NAME = "${workspacePath}/hotfix_filelist.txt"
    def FILE_LIST_PATH       = "${workspacePath}/hotfix_filelist.txt"

    try {

        stage('Git Fetch') {
            dir('playbooks') {
                wrap([$class: 'MaskPasswordsBuildWrapper',
                      varPasswordPairs: [[password: "${GLB_GITURL}", var: 'NULL']]]) {
                    git poll: false,
                        branch: "$BRANCH",
                        url: "$GLB_GITURL/phoenix/cicd-exb/"
                }
            }

            dir('eximbills') {
                git poll: false,
                    branch: "${EE_BRANCH}",
                    url: "${EE_REPO_URL}"
            }
        }

        stage('Validate PR') {
            withCredentials([string(credentialsId: GHE_CRED_ID, variable: 'GHE_TOKEN')]) {
                script {
                    def prApiUrl = "${GHE_API_BASE}/repos/${GHE_ORG}/${GHE_REPO}/pulls/${params.PR_NUMBER}"

                    def prResponse = sh(
                        script: """
                            curl -s -k \
                              -H "Authorization: token ${GHE_TOKEN}" \
                              -H "Accept: application/vnd.github.v3+json" \
                              "${prApiUrl}"
                        """,
                        returnStdout: true
                    ).trim()

                    def prJson = new JsonSlurper().parseText(prResponse)

                    if (prJson.message) {
                        error "GitHub API error: ${prJson.message}"
                    }

                    if (!prJson.merged) {
                        error "PR #${params.PR_NUMBER} is not merged (state: ${prJson.state}). Only merged PRs are allowed."
                    }

                    echo "PR #${params.PR_NUMBER}: ${prJson.title} -- validated (merged)"
                }
            }
        }

        stage('Fetch Commits from PR') {
            withCredentials([string(credentialsId: GHE_CRED_ID, variable: 'GHE_TOKEN')]) {
                script {
                    def commitsApiUrl = "${GHE_API_BASE}/repos/${GHE_ORG}/${GHE_REPO}/pulls/${params.PR_NUMBER}/commits?per_page=100"

                    def commitsResponse = sh(
                        script: """
                            curl -s -k \
                              -H "Authorization: token ${GHE_TOKEN}" \
                              -H "Accept: application/vnd.github.v3+json" \
                              "${commitsApiUrl}"
                        """,
                        returnStdout: true
                    ).trim()

                    def commitsJson = new JsonSlurper().parseText(commitsResponse)

                    if (commitsJson instanceof Map && commitsJson.message) {
                        error "GitHub API error fetching commits: ${commitsJson.message}"
                    }

                    if (commitsJson.size() == 0) {
                        error "No commits found for PR #${params.PR_NUMBER}"
                    }

                    env.COMMIT_LIST = commitsJson.collect { it.sha }.join('\n')
                    echo "Found ${commitsJson.size()} commit(s) in PR #${params.PR_NUMBER}"
                }
            }
        }

        stage('Fetch Changed Files') {
            dir('eximbills') {
                script {
                    def addedFiles = []
                    def modifiedFiles = []

                    env.COMMIT_LIST.split('\n').each { commit ->
                        commit = commit.trim()

                        sh "git cat-file -e '${commit}^{commit}'"

                        def nameStatus = sh(
                            script: """
                                git diff-tree --no-commit-id --name-status -r ${commit} -- 'jboss/' | grep -v '^\\s*\$' || true
                            """,
                            returnStdout: true
                        ).trim()

                        if (nameStatus) {
                            nameStatus.split('\n').each { line ->
                                def parts = line.trim().split("\\s+", 2)

                                if (parts.size() == 2) {
                                    if (parts[0] == 'A') {
                                        addedFiles.add(parts[1])
                                    } else {
                                        modifiedFiles.add(parts[1])
                                    }
                                }
                            }
                        }
                    }

                    addedFiles = addedFiles.unique()
                    modifiedFiles = modifiedFiles.unique()
                    def allChangedFiles = (addedFiles + modifiedFiles).unique()

                    if (allChangedFiles.size() == 0) {
                        error "No changed files found under 'jboss/' for PR #${params.PR_NUMBER}"
                    }

                    // Write file list to disk - never stored in env var to avoid E2BIG / ARG_MAX
                    // File list is newline-separated; playbook reads it via lookup('file')
                    writeFile file: FILE_LIST_PATH, text: allChangedFiles.join('\n')

                    def changedDirs = allChangedFiles.collect { f ->
                        def parts = f.split('/')
                        parts.length > 2 ? parts[0..1].join('/') : parts[0]
                    }.unique().sort()

                    def PRINT_THRESHOLD = 50

                    echo "============================================================"
                    echo "PR #${params.PR_NUMBER} - FILE CHANGE SUMMARY"
                    echo "============================================================"
                    echo "New files     : ${addedFiles.size()}"
                    echo "Modified files: ${modifiedFiles.size()}"
                    echo "Total files   : ${allChangedFiles.size()}"
                    echo "============================================================"

                    changedDirs.each { d ->
                        echo " - ${d}"
                    }

                    echo "============================================================"

                    if (addedFiles.size() > PRINT_THRESHOLD) {
                        echo "Added files (${addedFiles.size()}) - PRINT_THRESHOLD more (truncated)"
                    } else {
                        addedFiles.each { f -> echo "[NEW] ${f}" }
                    }

                    if (modifiedFiles.size() > PRINT_THRESHOLD) {
                        echo "Modified files (${modifiedFiles.size()}) - PRINT_THRESHOLD more (truncated)"
                    } else {
                        modifiedFiles.each { f -> echo "[MOD] ${f}" }
                    }

                    echo "============================================================"
                    echo "Total files : ${allChangedFiles.size()}"
                    echo "============================================================"
                    echo "Changed directories:"
                    changedDirs.each { d -> echo " - ${d}" }
                    echo "============================================================"
                    echo "Sleeping 15 seconds - review the above before build proceeds..."
                    sleep(time: 15, unit: 'SECONDS')
                }
            }
        }

        stage('Create Hotfix Archive') {
            script {
                def timeStamp = new Date().format('yyyyMMdd_HHmmss')
                HOTFIX_ARTIFACT_NAME = "eximbills-hotfix-PR${params.PR_NUMBER}_${timeStamp}.zip"

                echo "Artifact name: ${HOTFIX_ARTIFACT_NAME}"
                // FILE_LIST_PATH passed as a scalar path - file contents never touch a shell arg or env var
                ansiblePlaybook(
                    playbook: "playbooks/EXB-Hotfix-Build.pb",
                    extras: "-i playbooks/env/${ENVNAME} -e ENVNAME=${ENVNAME} -e WRK=${workspacePath} -e filelist_path=${FILE_LIST_PATH} -e artifact_name=${HOTFIX_ARTIFACT_NAME} -t precheck"
                )
            }
        }

        stage('Copy to Precheck Folder') {
            ansiblePlaybook(
                playbook: "playbooks/EXB-Hotfix-Build.pb",
                extras: "-i playbooks/env/${ENVNAME} -e ENVNAME=${ENVNAME} -e WRK=${workspacePath} -e filelist_path=${FILE_LIST_PATH} -e artifact_name=${HOTFIX_ARTIFACT_NAME} -t precheck"
            )

            echo "============================================================"
            echo "BUILD COMPLETE - AWAITING APP TEAM VERIFICATION"
            echo "============================================================"
            echo "Package  : ${HOTFIX_ARTIFACT_NAME}"
            echo "Location : <app_home>/Hotfix_Deploy_Precheck/${HOTFIX_ARTIFACT_NAME}"
            echo ""
            echo "Please verify package contents on the target server."
            echo "Then trigger EXB-Hotfix-Deploy with:"
            echo "  PACKAGENAME = ${HOTFIX_ARTIFACT_NAME}"
            echo "============================================================"
        }

    } finally {
        cleanWs()
    }
}
