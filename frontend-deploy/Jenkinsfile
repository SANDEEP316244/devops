@Library('jenkins-shared-library') _

// Parameters must be declared before any pipeline logic executes
properties([
  parameters([
    string(name: 'appVersion',   description: 'Enter Application version'),
    choice(name: 'deploy_to', choices: ['dev', 'qa', 'prod'], description: 'Target environment')
  ])
])

// Build configMap from params (with safe defaults)
def configMap = [
  project    : "roboshop",
  component  : "frontend",
  deploy_to: (params.deploy_to       ?: 'dev'),
  appVersion : (params.appVersion)
]

echo "Going to execute Jenkins shared library"
echo "ConfigMap: ${configMap}"

EKSDeploy(configMap)
