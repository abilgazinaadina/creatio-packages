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
                deleteDir()
                checkout scm
            }
        }

        stage('Wait for Creatio') {
            steps {
                sh '''
                    echo "Waiting for Creatio..."

                    for i in $(seq 1 30); do
                        if curl -fsS http://app:5000/Login/Login.html > /dev/null; then
                            echo "Creatio is responding"
                            sleep 10
                            exit 0
                        fi

                        echo "Creatio is not ready yet..."
                        sleep 5
                    done

                    echo "Creatio did not become ready"
                    exit 1
                '''
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

        stage('Wait after install') {
            steps {
                sh '''
                    echo "Waiting for Creatio..."

                    for i in $(seq 1 30); do
                        if curl -fsS http://app:5000/Login/Login.html > /dev/null; then
                            echo "Creatio is responding"
                            sleep 10
                            exit 0
                        fi

                        echo "Creatio is not ready yet..."
                        sleep 5
                    done

                    echo "Creatio did not become ready"
                    exit 1
                '''
            }
        }

        stage('Compile') {
            steps {
                sh '''
                    mkdir -p out

                    set +e
                    clio compile-configuration --all -e build
                    COMPILE_EXIT=$?
                    set -e

                    echo "clio exit code: $COMPILE_EXIT"

                    sleep 5

                    clio last-compilation-log -e build | tee out/compilation.log

                    if grep -q "Succeeded: True. Errors: 0" out/compilation.log; then
                        echo "Compilation actually succeeded"
                        exit 0
                    fi

                    echo "Compilation really failed"
                    exit 1
                '''
            }
        }

        stage('Smoke') {
            steps {
                sh 'cd smoke && bru run --env ci -r'
            }
        }

        stage('Prepare image') {
            steps {
                sh '''
                    echo "Preparing compiled package..."

                    rm -rf out/packages
                    mkdir -p out/packages

                    APP_CONTAINER=$(docker ps -q \
                      --filter "label=com.docker.compose.project=day1-stand" \
                      --filter "label=com.docker.compose.service=app" \
                      | head -n 1)

                    if [ -z "$APP_CONTAINER" ]; then
                        echo "Creatio app container not found"
                        exit 1
                    fi

                    docker cp \
                      "$APP_CONTAINER:/app/Terrasoft.Configuration/Pkg/MeDev" \
                      out/packages/

                    test -f out/packages/MeDev/Files/Bin/netstandard/MeDev.dll

                    echo "Compiled MeDev package prepared"
                '''
            }
        }

        stage('Bake image') {
            steps {
                script {
                    def sha = sh(
                        script: 'git rev-parse --short=8 HEAD',
                        returnStdout: true
                    ).trim()

                    def img = "localhost:5002/creatio-stand"

                    echo "Image tag: ${sha}"

                    sh """
                        docker build \
                          -t ${img}:${sha} \
                          -t ${img}:build-${env.BUILD_NUMBER} \
                          .
                    """

                    sh "docker push ${img}:${sha}"
                    sh "docker push ${img}:build-${env.BUILD_NUMBER}"

                    env.IMAGE_TAG = sha

                    sh """
                        echo "${img}:${sha}" > out/image.txt
                        echo "${img}:build-${env.BUILD_NUMBER}" >> out/image.txt
                    """
                }
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