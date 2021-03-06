#!/bin/bash

: '
#SYNOPSIS
    Deployment of config and related resources for config based data collection.
.DESCRIPTION
    This script will deploy all the services required for the config based data collection.

.NOTES

    Copyright (c) Cloudneeti. All rights reserved.
    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is  furnished to do so, subject to the following conditions:
    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

    Version: 1.0
    # PREREQUISITE
      - Install aws cli
        Link : https://docs.aws.amazon.com/cli/latest/userguide/install-linux-al2017.html
      - Install json parser jq
        Installation command: sudo apt-get install jq
      - Configure your aws account using the below command:
        aws configure
        Enter the required inputs:
            AWS Access Key ID: Access key of any admin user of the account in consideration.
            AWS Secret Access Key: Secret Access Key of any admin user of the account in consideration
            Default region name: Programmatic region name where you want to deploy the framework (eg: us-east-1)
            Default output format: json  
      - Run this script in any bash shell (linux command prompt)
.EXAMPLE
    Command to execute : bash deploy-config.sh [-a <12-digit-account-id>] [-e <environment-prefix>] [-n <config-aggregator-name>] [-p <primary-aggregator-region>] [-s <list of regions(secondary) where config is to enabled>]
.INPUTS
    (-a)Account Id: 12-digit AWS account Id of the account where you want to deploy the AWS Config setup
    (-e)Environment prefix: Enter any suitable prefix for your deployment
    (-n)Config Aggregator Name: Suitable name for the config aggregator
    (-p)Config Aggregator region(primary): Programmatic name of the region where the the primary config with an aggregator is to be created(eg:us-east-1)
    (-s)Region list(secondary): Comma seperated list(with nos spaces) of the regions where the config(secondary) is to be enabled(eg: us-east-1,us-east-2)
        **Pass "all" if you want to enable config in all other available regions
        **Pass "na" if you do not want to enable config in any other region
.OUTPUTS
    None
'

usage() { echo "Usage: $0 [-a <12-digit-account-id>] [-e <environment-prefix>] [-n <config-aggregator-name>] [-p <primary-aggregator-region>] [-s <list of regions(secondary) where config is to enabled>]" 1>&2; exit 1; }
aggregion_validation() { echo "Enter correct value for the aggregator region parameter. Following are the acceptable values: ${aggregator_regions[@]}" 1>&2; exit 1; }
region_validation() { echo "Enter correct value(s) for the secondary region parameter. Following are the acceptable values: ${enabled_regions[@]}" 1>&2; exit 1; }

env="dev"
regionlist=("na")

while getopts "a:e:n:p:s:" o; do
    case "${o}" in
        a)
            awsaccountid=${OPTARG}
            ;;
        e)
            env=${OPTARG}
            ;;
        n)
            aggregatorname=${OPTARG}
            ;;
        p)
            aggregatorregion=${OPTARG}
            ;;
		s)  
            regionlist=${OPTARG}
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

if [[ "$awsaccountid" == "" ]] || ! [[ "$awsaccountid" =~ ^[0-9]+$ ]] || [[ ${#awsaccountid} != 12 ]] || [[ "$aggregatorname" == "" ]]; then
    usage
fi

echo "Validating input parameters..."

region_detail="$(aws ec2 describe-regions | jq '.Regions')"
region_count="$(echo $region_detail | jq length)"

aws_regions=()
for ((i = 0 ; i < region_count ; i++ )); do
    aws_regions+=("$(echo $region_detail | jq -r --arg i "$i" '.[$i | tonumber]' | jq '.RegionName')")
done

enabled_regions=()
for index in ${!aws_regions[@]}
do
    enabled_regions+=("$(echo ${aws_regions[index]//\"/})")
done

aggregator_regions=( "us-east-1" "us-east-2" "us-west-1" "us-west-2" "ap-south-1" "ap-northeast-2" "ap-southeast-1" "ap-southeast-2" "ap-northeast-1" "ca-central-1" "eu-central-1" "eu-west-1" "eu-west-2" "eu-west-3" "eu-north-1" "sa-east-1")

new_regions=()
for i in "${enabled_regions[@]}"; do
    skip=
    for j in "${aggregator_regions[@]}"; do
        [[ $i == $j ]] && { skip=1; break; }
    done
    [[ -n $skip ]] || new_regions+=("$i")
done

configure_account="$(aws sts get-caller-identity)"

if [[ "$configure_account" != *"$awsaccountid"* ]];then
    echo "AWS CLI configuration AWS account Id and entered AWS account Id does not match. Please try again with correct AWS Account Id."
    exit 1
fi

env="$(echo "$env" | tr "[:upper:]" "[:lower:]")"
aggregatorname="$(echo "$aggregatorname" | tr "[:upper:]" "[:lower:]")"
aggregatorregion="$(echo "$aggregatorregion" | tr "[:upper:]" "[:lower:]")"
regionlist="$(echo "$regionlist" | tr "[:upper:]" "[:lower:]")"

if [[ " ${aggregator_regions[*]} " != *" $aggregatorregion "* ]] || [[ " ${aggregatorregion} " != *" $aggregatorregion "* ]]; then
    aggregion_validation
fi

if [[ $regionlist == "all" ]]; then
    input_regions="${enabled_regions[@]}"
elif [[ $regionlist == "na" ]]; then
    input_regions=("na")
else
    IFS=, read -a input_regions <<<"${regionlist}"
    printf -v ips ',"%s"' "${input_regions[@]}"
    ips="${ips:1}"
fi

input_regions=($(echo "${input_regions[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

if [[ $regionlist != "all" ]] && [[ $regionlist != "na" ]]; then
    validated_regions=()
    for i in "${input_regions[@]}"; do
        for j in "${enabled_regions[@]}"; do
            if [[ $i == $j ]]; then
                validated_regions+=("$i")
            fi
        done
    done

    if [[ ${#validated_regions[@]} != ${#input_regions[@]} ]]; then
        region_validation
    fi
fi

read -p "This script will update any existing config setup present in entered regions of the AWS Account: $awsaccountid, as per Cloudneeti requirements. Continue? (Y/N): " confirm && [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]] || exit 1

echo "Verifying if the config aggregator or the config deployment bucket with the similar environment prefix exists in the account..."
s3_detail="$(aws s3api get-bucket-versioning --bucket config-bucket-$env-$awsaccountid 2>/dev/null)"
s3_status=$?

stack_detail="$(aws cloudformation describe-stacks --stack-name "cn-data-collector-"$env --region $aggregatorregion 2>/dev/null)"
stack_status=$?

if [[ $s3_status -eq 0 ]] && [[ $stack_status != 0 ]]; then
    echo "Config bucket with name config-bucket-$env-$awsaccountid already exists in the account. Please verify if a cloudneeti aggregator (primary config) already exists in some other region or re-run the script with different environment variable."
    exit 1
fi

if [[ $s3_status != 0 ]] && [[ $stack_status -eq 0 ]]; then
    echo "Config stack with name cn-data-collector-$env already exists in the account but the associated bucket has been deleted. Please delete the stack and re-run the script."
    exit 1
fi

echo "Fetching details for any existing config setup in the primary region: $aggregatorregion"
config_recorder="$(aws configservice describe-configuration-recorders --region $aggregatorregion | jq '.ConfigurationRecorders[0].name')"
role_arn="$(aws configservice describe-configuration-recorders --region $aggregatorregion | jq '.ConfigurationRecorders[0].roleARN')"
delivery_channel="$(aws configservice describe-delivery-channels --region $aggregatorregion | jq '.DeliveryChannels[0].name')"

if [[ $config_recorder != null ]] && [[ $delivery_channel != null ]]; then
    echo "Found existing config setup!! Enhancing existing config setup to record all the resource types including global in the primary region..."
    aws configservice put-configuration-recorder --configuration-recorder name=$config_recorder,roleARN=$role_arn --recording-group allSupported=true,includeGlobalResourceTypes=true --region $aggregatorregion 2>/dev/null
    config_status=$?
    if [[ $config_status -eq 0 ]]; then        
        aws configservice put-configuration-aggregator --region $aggregatorregion --configuration-aggregator-name $aggregatorname --account-aggregation-sources AccountIds=$awsaccountid,AllAwsRegions=true 2>/dev/null
        aggregator_status=$?
    else
        echo "Error updating existing setup. Please contact Cloudneeti support!"
    fi
else
    echo "No existing config setup found. Deploying new config setup and aggregator in the primary region: $aggregatorregion"
    aws cloudformation deploy --template-file config-aggregator.yml --stack-name "cn-data-collector-"$env --region $aggregatorregion --parameter-overrides env=$env awsaccountid=$awsaccountid aggregatorname=$aggregatorname --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset
    aggregator_status=$?
fi

if [[ "$aggregator_status" -eq 0 ]] && [[ "${input_regions[0]}" != "na" ]]; then
    for region in "${input_regions[@]}"; do
        if [[ "$region" != "$aggregatorregion" ]]; then
            echo "Fetching details for any existing config setup in the secondary region: $region"
            config_recorder="$(aws configservice describe-configuration-recorders --region $region | jq '.ConfigurationRecorders[0].name')"
            role_arn="$(aws configservice describe-configuration-recorders --region $region | jq '.ConfigurationRecorders[0].roleARN')"
            delivery_channel="$(aws configservice describe-delivery-channels --region $region | jq '.DeliveryChannels[0].name')"

            if [[ $config_recorder -ne null ]] && [[ $delivery_channel -ne null ]]; then
                echo "Found existing config setup!! Enhancing existing config setup to record all the resource types in the secondary region..."
                aws configservice put-configuration-recorder --configuration-recorder name=$config_recorder,roleARN=$role_arn --recording-group allSupported=true,includeGlobalResourceTypes=false --region $region 2>/dev/null
                multiregionconfig_status=$?
            else
                if [[ " ${new_regions[*]} " == *" $region "* ]]; then
                    echo "No existing config setup found. Deploying/Re-deploying config in the secondary region: $region."
                    aws cloudformation deploy --template-file newregion-config.yml --stack-name "cn-data-collector-"$env --region $region --parameter-overrides env=$env awsaccountid=$awsaccountid --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset
                    multiregionconfig_status=$?
                else
                    echo "No existing config setup found. Deploying/Re-deploying config in the secondary region: $region."
                    aws cloudformation deploy --template-file multiregion-config.yml --stack-name "cn-data-collector-"$env --region $region --parameter-overrides env=$env awsaccountid=$awsaccountid aggregatorregion=$aggregatorregion --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset
                    multiregionconfig_status=$?
                fi
            fi
        fi
    done

elif [[ "${input_regions[0]}" == "na" ]] || [[ "$multiregionconfig_status" -eq 0 ]]; then
    echo "Successfully deployed/updated config(s) and aggregator in the mentioned regions!!"

elif [[ "${input_regions[0]}" == "na" ]]; then
    echo "Successfully deployed/updated config and aggregator in the mentioned region!!"

else
    echo "Something went wrong! Please contact Cloudneeti support for more details"
fi