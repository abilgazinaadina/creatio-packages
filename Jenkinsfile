pipeline {

    agent {
        label 'docker'
    }

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


        stage('Wait for Build Creatio') {
            steps {
                sh '''
                    echo "Waiting for build Creatio..."

                    for i in $(seq 1 30); do

                        if curl -fsS http://build-app:5000/Login/Login.html > /dev/null; then
                            echo "Build Creatio is responding"
                            sleep 10
                            exit 0
                        fi

                        echo "Build Creatio is not ready yet..."
                        sleep 5
                    done

                    echo "Build Creatio did not become ready"
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
                          -u http://build-app:5000 \
                          -l "$CREATIO_USER" \
                          -p "$CREATIO_PASSWORD"
                    '''
                }
            }
        }


        stage('Install packages') {
            steps {
                sh '''
                    clio push-workspace -e build
                '''
            }
        }


        stage('Wait after install') {
            steps {
                sh '''
                    echo "Waiting for build Creatio after package installation..."

                    for i in $(seq 1 30); do

                        if curl -fsS http://build-app:5000/Login/Login.html > /dev/null; then
                            echo "Build Creatio is responding"
                            sleep 10
                            exit 0
                        fi

                        echo "Build Creatio is not ready yet..."
                        sleep 5
                    done

                    echo "Build Creatio did not become ready"
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

                    clio last-compilation-log -e build \
                      | tee out/compilation.log

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
                sh '''
                    cd smoke
                    bru run --env ci -r
                '''
            }
        }


        stage('Prepare DB snapshot') {
            steps {
                script {

                    def sha = sh(
                        script: 'git rev-parse --short=8 HEAD',
                        returnStdout: true
                    ).trim()


                    withEnv(["SNAPSHOT_SHA=${sha}"]) {

                        sh '''
                            DB_CONTAINER=$(docker ps -q \
                              --filter "label=com.docker.compose.project=day1-stand" \
                              --filter "label=com.docker.compose.service=db" \
                              | head -n 1)


                            if [ -z "$DB_CONTAINER" ]; then
                                echo "PostgreSQL container not found"
                                exit 1
                            fi


                            echo "Creating DB snapshot: creatio_snap_${SNAPSHOT_SHA}"


                            docker exec -i "$DB_CONTAINER" \
                              psql -U postgres -d postgres -c "
                                SELECT pg_terminate_backend(pid)
                                FROM pg_stat_activity
                                WHERE datname = 'creatio_ref'
                                  AND pid <> pg_backend_pid();
                              "


                            docker exec -i "$DB_CONTAINER" \
                              psql -U postgres -d postgres -c "
                                DROP DATABASE IF EXISTS creatio_snap_${SNAPSHOT_SHA};
                              "


                            docker exec -i "$DB_CONTAINER" \
                              psql -U postgres -d postgres -c "
                                CREATE DATABASE creatio_snap_${SNAPSHOT_SHA}
                                TEMPLATE creatio_ref;
                              "


                            echo "Snapshot creatio_snap_${SNAPSHOT_SHA} created"
                        '''
                    }
                }
            }
        }


        stage('Prepare image') {
            steps {
                sh '''
                    echo "Preparing compiled package from build-app..."

                    rm -rf out/packages
                    mkdir -p out/packages


                    BUILD_APP_CONTAINER=$(docker ps -q \
                      --filter "label=com.docker.compose.project=day1-stand" \
                      --filter "label=com.docker.compose.service=build-app" \
                      | head -n 1)


                    if [ -z "$BUILD_APP_CONTAINER" ]; then
                        echo "Build Creatio container not found"
                        exit 1
                    fi


                    docker cp \
                      "$BUILD_APP_CONTAINER:/app/Terrasoft.Configuration/Pkg/MeDev" \
                      out/packages/


                    test -f \
                      out/packages/MeDev/Files/Bin/netstandard/MeDev.dll


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


                    sh """
                        docker push ${img}:${sha}
                    """


                    sh """
                        docker push ${img}:build-${env.BUILD_NUMBER}
                    """


                    env.IMAGE_TAG = sha


                    sh """
                        echo "${img}:${sha}" > out/image.txt
                        echo "${img}:build-${env.BUILD_NUMBER}" >> out/image.txt
                    """
                }
            }
        }


        /*
         * Временный Kubernetes stand создаём
         * ТОЛЬКО для feature-веток.
         *
         * master проходит CI, но отдельный stand-master
         * больше не создаётся.
         */
        stage('Deploy stand') {

            when {
                expression {
                    return env.BRANCH_NAME &&
                           env.BRANCH_NAME != 'master'
                }
            }

            steps {
                script {

                    def sha = sh(
                        script: 'git rev-parse --short=8 HEAD',
                        returnStdout: true
                    ).trim()


                    def branch = env.BRANCH_NAME


                    echo """
                    ----------------------------------------
                    Trigger stand deployment

                    Branch:    ${branch}
                    Image tag: ${sha}
                    TTL:       24h

                    ----------------------------------------
                    """


                    /*
                     * wait:false важен.
                     *
                     * Основной CI освобождает единственный
                     * docker-agent, после чего stand-deploy
                     * сможет получить этот agent.
                     */
                    build job: 'creatio-stand-deploy',
                        wait: false,
                        parameters: [

                            string(
                                name: 'BRANCH',
                                value: branch
                            ),

                            string(
                                name: 'IMAGE_TAG',
                                value: sha
                            ),

                            string(
                                name: 'TTL_HOURS',
                                value: '24'
                            )
                        ]


                    echo "Stand deployment scheduled."
                    echo "Main CI does not wait for stand deployment."
                }
            }
        }

    }


    post {

        success {
            echo 'CI completed successfully.'
        }


        failure {
            echo 'Сборка упала — смотри, на какой стадии'
        }


        always {

            archiveArtifacts(
                artifacts: 'out/**',
                allowEmptyArchive: true
            )
        }
    }
}