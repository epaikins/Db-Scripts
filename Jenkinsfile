/**
 * Jenkins Pipeline: MySQL fast backup/restore (50GB+, sub-1hr target)
 *
 * Prerequisites:
 * - Jenkins credentials (Secret text): add two credentials containing MySQL passwords only:
 *   - SOURCE_CREDENTIAL_ID: source MySQL password
 *   - TARGET_CREDENTIAL_ID: target MySQL password
 * - Agent with mydumper/myloader (or mysqldump/mysql) and network access to both MySQL servers
 *
 * First run: set SOURCE_CREDENTIAL_ID and TARGET_CREDENTIAL_ID in job parameters to your credential IDs.
 */
pipeline {
  agent any

  options {
    timeout(time: 90, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '10'))
    timestamps()
  }

  parameters {
    choice(
      name: 'MODE',
      choices: ['full', 'backup-only', 'restore-only'],
      description: 'full = backup then restore; backup-only / restore-only for split runs'
    )
    string(
      name: 'BACKUP_PATH',
      defaultValue: '',
      description: 'For restore-only: path to backup dir (e.g. ./backups/mydb_20250223_120000 or absolute path)'
    )
    string(name: 'SOURCE_HOST', defaultValue: 'source-mysql.example.com', description: 'Source MySQL host')
    string(name: 'SOURCE_PORT', defaultValue: '3306', description: 'Source MySQL port')
    string(name: 'SOURCE_USER', defaultValue: 'backup_user', description: 'Source MySQL user')
    string(name: 'SOURCE_CREDENTIAL_ID', defaultValue: '', description: 'Jenkins credential ID (Secret text) for source MySQL password')
    string(name: 'SOURCE_DATABASE', defaultValue: 'your_database', description: 'Source database name')
    string(name: 'TARGET_HOST', defaultValue: 'target-mysql.example.com', description: 'Target MySQL host')
    string(name: 'TARGET_PORT', defaultValue: '3306', description: 'Target MySQL port')
    string(name: 'TARGET_USER', defaultValue: 'restore_user', description: 'Target MySQL user')
    string(name: 'TARGET_CREDENTIAL_ID', defaultValue: '', description: 'Jenkins credential ID (Secret text) for target MySQL password')
    string(name: 'TARGET_DATABASE', defaultValue: 'your_database', description: 'Target database name')
    string(name: 'BACKUP_DIR', defaultValue: './backups', description: 'Local backup output directory')
    string(name: 'REMOTE_BACKUP_PATH', defaultValue: '', description: 'Optional: user@host:/path for rsync after backup')
    string(name: 'S3_BUCKET', defaultValue: '', description: 'Optional: S3 bucket; after backup push to S3; for restore-only use BACKUP_PATH=s3://bucket/prefix/key')
    string(name: 'S3_PREFIX', defaultValue: 'mysql-backups', description: 'S3 key prefix when S3_BUCKET is set')
    string(name: 'AWS_REGION', defaultValue: 'us-east-1', description: 'AWS region for S3')
    string(name: 'AWS_CREDENTIAL_ID', defaultValue: '', description: 'Optional: Jenkins AWS credential ID for S3 (required if S3_BUCKET is set)')
    string(name: 'PARALLEL_JOBS', defaultValue: '16', description: 'Parallel threads (backup)')
    string(name: 'RESTORE_THREADS', defaultValue: '', description: 'Optional: myloader threads (default PARALLEL_JOBS; use 1 or 2 if myloader crashes)')
    string(name: 'CHUNK_SIZE_MB', defaultValue: '64', description: 'Chunk size in MB for mydumper')
    choice(name: 'COMPRESS', choices: ['1', '0'], description: 'Compress backup (1=yes)')
    choice(name: 'BACKUP_TOOL', choices: ['mydumper', 'mysqldump'], description: 'Backup tool preference')
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Prepare config') {
      steps {
        script {
          def creds = []
          if (params.SOURCE_CREDENTIAL_ID?.trim()) {
            creds.add(string(credentialsId: params.SOURCE_CREDENTIAL_ID.trim(), variable: 'SOURCE_PASS'))
          }
          if (params.TARGET_CREDENTIAL_ID?.trim()) {
            creds.add(string(credentialsId: params.TARGET_CREDENTIAL_ID.trim(), variable: 'TARGET_PASS'))
          }
          if (creds.isEmpty()) {
            error 'Create two "Secret text" credentials in Jenkins with MySQL passwords and set SOURCE_CREDENTIAL_ID and TARGET_CREDENTIAL_ID parameters.'
          }
          withCredentials(creds) {
            def sourcePass = params.SOURCE_CREDENTIAL_ID?.trim() ? (env.SOURCE_PASS ?: '') : ''
            def targetPass = params.TARGET_CREDENTIAL_ID?.trim() ? (env.TARGET_PASS ?: '') : ''
            writeFile file: 'config.env', text: """\
SOURCE_HOST=${params.SOURCE_HOST}
SOURCE_PORT=${params.SOURCE_PORT}
SOURCE_USER=${params.SOURCE_USER}
SOURCE_PASSWORD=${sourcePass}
SOURCE_DATABASE=${params.SOURCE_DATABASE}
TARGET_HOST=${params.TARGET_HOST}
TARGET_PORT=${params.TARGET_PORT}
TARGET_USER=${params.TARGET_USER}
TARGET_PASSWORD=${targetPass}
TARGET_DATABASE=${params.TARGET_DATABASE}
BACKUP_DIR=${params.BACKUP_DIR}
REMOTE_BACKUP_PATH=${params.REMOTE_BACKUP_PATH}
S3_BUCKET=${params.S3_BUCKET}
S3_PREFIX=${params.S3_PREFIX}
AWS_REGION=${params.AWS_REGION}
PARALLEL_JOBS=${params.PARALLEL_JOBS}
RESTORE_THREADS=${params.RESTORE_THREADS}
CHUNK_SIZE_MB=${params.CHUNK_SIZE_MB}
COMPRESS=${params.COMPRESS}
BACKUP_TOOL=${params.BACKUP_TOOL}
"""
          }
        }
      }
    }

    stage('Backup / Restore') {
      steps {
        script {
          def cmd = "./workflow.sh ${params.MODE}"
          if (params.MODE == 'restore-only') {
            if (!params.BACKUP_PATH?.trim()) {
              error "restore-only requires BACKUP_PATH parameter (local path or s3://bucket/prefix/key)"
            }
            cmd += " '${params.BACKUP_PATH.trim().replace("'", "'\\''")}'"
          }
          def useAws = params.AWS_CREDENTIAL_ID?.trim() && (
            params.S3_BUCKET?.trim() ||
            (params.MODE == 'restore-only' && params.BACKUP_PATH?.trim()?.startsWith('s3://'))
          )
          if (useAws) {
            withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: params.AWS_CREDENTIAL_ID.trim()]]) {
              sh cmd
            }
          } else {
            sh cmd
          }
        }
      }
    }
  }

  post {
    always {
      sh 'rm -f config.env'
    }
    success {
      echo 'MySQL backup/restore completed successfully.'
    }
    failure {
      echo 'MySQL backup/restore failed. Check logs.'
    }
  }
}
