node("${ENV}") {
    cleanWs()

    def workspacePath = env.WORKSPACE

    try {

        stage('Git Fetch') {
            dir('playbooks') {
                wrap([$class: 'MaskPasswordsBuildWrapper',
                      varPasswordPairs: [[password: "$GLB_GITURL", var: 'NULL']]]) {
                    git poll: false,
                        branch: "$BRANCH",
                        url: "$GLB_GITURL/phoenix/cicd-exb/"
                }
            }
        }

        stage('Verify Package Exists') {
            ansiblePlaybook(
                playbook: "playbooks/EXB-Hotfix-Deploy.pb",
                extras: "-i playbooks/env/${ENVNAME} -e ENVNAME=${ENVNAME} -e artifact_name=${params.PACKAGENAME} -t verify"
            )
        }

        stage('Upload to Nexus') {
            ansiblePlaybook(
                playbook: "playbooks/EXB-Hotfix-Deploy.pb",
                extras: "-i playbooks/env/${ENVNAME} -e ENVNAME=${ENVNAME} -e artifact_name=${params.PACKAGENAME} -t upload"
            )
        }

        stage('Hotfix Deployment') {
            ansiblePlaybook(
                playbook: "playbooks/EXB-Hotfix-Deploy.pb",
                extras: "-i playbooks/env/${ENVNAME} -e ENVNAME=${ENVNAME} -e artifact_name=${params.PACKAGENAME} -e jboss_restart=${params.JBOSS_RESTART} -t deploy"
            )
        }

    } finally {
        cleanWs()
    }
}
