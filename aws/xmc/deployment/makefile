# Make file for Xcalar Management Console
# 1- Create temporary directories for build.
# 2- Pull XMC source code from git repo 
# 3- Replace placeholder variables in source code
# 4- Zip lambda codes in zip files (required by cfn template)
# 5- Upload everything to given bucket
# After this make file is successfully run , two cfn templates are uploaded to:
# s3://$(BUCKET_NAME)/xmc/dep.yaml
# s3://$(BUCKET_NAME)/xmc/dep_ui.yaml
#
# To install XMC , customer should run these two cloudformation templates (firt dep.yaml then dep_ui.yaml)
# If everything goes well a new directory 3://$(BUCKET_NAME)/xmc/ui should be created with ui files
# Once Xcalar reference bucket has all files in it , policy below shoul be added to bucket policies.
# This policy allows customer account to copy files from xcalar bucket to their own bucket (cross bucket permissions)
# simply replace CUSTOMER_ACCOUNT_NUMBER with customer account and attach the policy to Xcalar reference bucket
#{
#    "Version": "2012-10-17",
#    "Statement": [
#        {
#            "Sid": "Example permissions",
#            "Effect": "Allow",
#            "Principal": {
#                "AWS": "arn:aws:iam::CUSTOMER_ACCOUNT_NUMBER:root"
#            },
#            "Action": [
#                "s3:GetBucketLocation",
#                "s3:ListBucket"
#            ],
#            "Resource": "arn:aws:s3:::abilgintest"
#        }
#    ]
#}

TABLE_NAME = xmc_table#<< DYNAMO TABLE NAME , just leave it as is unless multiple instances of the tool needed on one AWS account
BUCKET_NAME = abilgintest# << Xcalar reference bucket, customer should have the exact same structure and content in their own bucket
VERSION = 1
AWS_PROFILE = default# << AWS Account profile stored in &HOME/.aws/credentials file
REGION = us-west-2# Region of the reference s3 bucket, it is used by script to build path of cfn yaml files

# STEP 5 - Copy everything to Xcalar reference bucket
finalize: stage
	aws --profile $(AWS_PROFILE) s3 cp --recursive --acl public-read ./stage/src s3://$(BUCKET_NAME)/xmc
	echo Cloudformation template files locations
	echo https://s3-$(REGION).amazonaws.com/abilgintest/xmc/dep.yaml
	echo https://s3-$(REGION).amazonaws.com/abilgintest/xmc/dep_ui.yaml
	echo Provide these links to customer
	
# STEP 1 - Create Temporary directories
directories : 
	rm -rf ./stage
	rm -rf ./client  
	rm -rf ./source_base
	rm -rf ./package
	mkdir stage
	mkdir stage/src
	mkdir source_base
	mkdir source_base/ui
	
# STEP 2 - pull source code from git , extract it #FIXME : right now it copies files from my local disk 
copy_source : directories
	cp -r ../templates ./source_base
	cp -r ../lambda ./source_base/lambda
	cp -r ../ui/* ./source_base/ui

# STEP 3 - copy source code to temporary folders , replace dynamo table names in source code with given instance name
sed_ops : copy_source
	sed 's/XMC_TABLE_NAME/$(TABLE_NAME)/g' ./source_base/lambda/getFromDB.js > ./stage/src/getFromDB.js
	sed 's/XMC_TABLE_NAME/$(TABLE_NAME)/g' ./source_base/lambda/postToDB.js > ./stage/src/postToDB.js
	sed 's/XMC_TABLE_NAME/$(TABLE_NAME)/g' ./source_base/lambda/createCluster.js > ./stage/src/createCluster.js
	sed 's/XMC_TABLE_NAME/$(TABLE_NAME)/g' ./source_base/lambda/deleteCluster.js > ./stage/src/deleteCluster.js
	sed 's/XMC_TABLE_NAME/$(TABLE_NAME)/g' ./source_base/lambda/listClusters.js > ./stage/src/listClusters.js
	sed 's/XMC_TABLE_NAME/$(TABLE_NAME)/g' ./source_base/templates/dep.yaml.template > ./stage/src/dep.yaml
	sed 's/XMC_TABLE_NAME/$(TABLE_NAME)/g' ./source_base/templates/dep_ui.yaml.template > ./stage/src/dep_ui.yaml
	cp ./source_base/templates/cfn_template ./stage/src
	cp ./source_base/lambda/parser.js ./stage/src
	cp -r ./source_base/ui ./stage/src
	rm -rf ./stage/src/ui/node_modules 
		
# STEP 4 - create zip files for lambdas , clean up rest
stage : sed_ops
	zip -j ./stage/src/createCluster.zip ./stage/src/createCluster.js ./stage/src/cfn_template
	zip -j ./stage/src/listClusters.zip ./stage/src/listClusters.js ./stage/src/parser.js
	zip -j ./stage/src/deleteCluster.zip ./stage/src/deleteCluster.js
	zip -j ./stage/src/postToDB.zip ./stage/src/postToDB.js
	zip -j ./stage/src/getFromDB.zip ./stage/src/getFromDB.js
	rm ./stage/src/*.js
	rm ./stage/src/cfn_template	

    	