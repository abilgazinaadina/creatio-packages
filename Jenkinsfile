pipeline {
    agent { label 'docker' }

    options {
        skipDefaultCheckout(true)
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Configure clio') {
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'creatio-build',
                        usernameVariable: 'CREATIO_USER',
                        passwordVariable: 'CREATIO_PASSWORD'
                    )
                ]) {
                    sh '''
                        clio reg-web-app build \
                          -u http://app:5000 \
                          -l "$CREATIO_USER" \
                          -p "$CREATIO_PASSWORD"
                    '''
                }
            }
        }

        stage('Install packages') {
            steps {
                sh 'clio push-workspace -e build'
            }
        }

        stage('Compile') {
            steps {
                sh 'clio compile-configuration --all -e build'
            }
        }

        stage('Smoke') {
            steps {
                sh 'cd smoke && bru run --env ci -r'
            }
        }
    }

    post {
        failure {
            echo 'Сборка упала — смотри, на какой стадии'
        }

        always {
            archiveArtifacts artifacts: 'out/**', allowEmptyArchive: true
        }
    }
}