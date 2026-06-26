@Library('jenkins-shared-library') _

def configMap = [
    project : "roboshop",
    component: "frontend"
]

if( ! env.BRANCH_NAME.equalsIgnoreCase('main') ){ // if not equals to main
    nodeJSEKSPipeline(configMap) // by default it will call, call function inside this pipeline
}
else{
    echo "Please proceed with PROD process"
}