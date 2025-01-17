version 1.0

import "../../../tasks/task_versioning.wdl" as versioning_task

workflow basespace_fetch {
  input {
    String sample_name
    String basespace_sample_name
    String? basespace_sample_id
    String basespace_collection_id
    String api_server
    String access_token
  }
  call fetch_bs {
    input:
      sample_name = sample_name,
      basespace_sample_id = basespace_sample_id,
      basespace_sample_name = basespace_sample_name,
      basespace_collection_id = basespace_collection_id,
      api_server = api_server,
      access_token = access_token
  }
  call versioning_task.version_capture {
    input:
  }
  output {
    String basespace_fetch_version = version_capture.phb_version
    String basespace_fetch_analysis_date = version_capture.date
    
    File read1 = fetch_bs.read1
    File? read2 = fetch_bs.read2
  }
}

task fetch_bs {
  input {
    String sample_name
    String basespace_sample_name
    String? basespace_sample_id
    String basespace_collection_id
    String api_server
    String access_token
    Int mem_size_gb=8
    Int CPUs = 2
    Int disk_size = 100
    Int Preemptible = 1
  }
  command <<<
    # set basespace name and id variables
    if [[ ! -z "~{basespace_sample_id}" ]]
    then
      sample_identifier="~{basespace_sample_name}"
      dataset_name="~{basespace_sample_id}"
    else
      sample_identifier="~{basespace_sample_name}"
      dataset_name="~{basespace_sample_name}"
    fi
    
    # print all relevant input variables to stdout
    echo -e "sample_identifier: ${sample_identifier}\ndataset_name: ${dataset_name}\nbasespace_collection_id: ~{basespace_collection_id}"
      
    #Set BaseSpace comand prefix
    bs_command="bs --api-server=~{api_server} --access-token=~{access_token}"
    echo "bs_command: ${bs_command}"

    #Grab BaseSpace Run_ID from given BaseSpace Run Name
    run_id=$(${bs_command} list run | grep "~{basespace_collection_id}" | awk -F "|" '{ print $3 }' | awk '{$1=$1;print}' )
    echo "run_id: ${run_id}" 
    if [[ ! -z "${run_id}" ]]
    then 
      #Grab BaseSpace Dataset ID from dataset lists within given run 
      dataset_id_array=($(${bs_command} list dataset --input-run=${run_id} | grep "${dataset_name}" | awk -F "|" '{ print $3 }' )) 
      echo "dataset_id: ${dataset_id_array[*]}"
    else 
      #Try Grabbing BaseSpace Dataset ID from project name
      project_id=$(${bs_command} list project | grep "~{basespace_collection_id}" | awk -F "|" '{ print $3 }' | awk '{$1=$1;print}' )
      echo "project_id: ${project_id}" 
      if [[ ! -z "${project_id}" ]]
      then 
        dataset_id_array=($(${bs_command} list dataset --project-id=${run_id} | grep "${dataset_name}" | awk -F "|" '{ print $3 }' )) 
        echo "dataset_id: ${dataset_id_array[*]}"
      else       
        echo "No run or project id found associated with input basespace_collection_id: ~{basespace_collection_id}" >&2
        exit 1
      fi      
    fi

    #Download reads by dataset ID
    echo "NOW EXECUTING DCM VARIANT OF THIS WORKFLOW" >&2
    for index in ${!dataset_id_array[@]}; do
      dataset_id=${dataset_id_array[$index]}
      mkdir ./dataset_${dataset_id} && cd ./dataset_${dataset_id}
      echo "dataset download: ${bs_command} download dataset -i ${dataset_id} -o . --retry"
      ${bs_command} download dataset -i ${dataset_id} -o . --retry && cd ..
      echo -e "downloaded data: $(ls ./dataset_*/*)"
    done

    #Combine non-empty read files into single file without BaseSpace filename cruft
    ##FWD Read
    echo "Starting read filename consolidation; I am in the dir:"
    echo "$(pwd)"
    echo "And I am seeing the contents:"
    echo "$(ls -ahl)"
    echo "I am next going to look in the dir '../dataset_${dataset_id}."
    echo "I am seeing:"
    echo "$(ls -ahl ./dataset_${dataset_id})"
    lane_count=0
    # for fwd_read in ./dataset_*/${sample_identifier}_*R1_*.fastq.gz; do
    for fwd_read in ./dataset_${dataset_id}/*_*R1_*.fastq.gz; do
      if [[ -s $fwd_read ]]; then
        echo "cat fwd reads: cat $fwd_read >> ~{sample_name}_R1.fastq.gz" 
        cat $fwd_read >> ~{sample_name}_R1.fastq.gz
        lane_count=$((lane_count+1))
      fi
    done
    ##REV Read
    for rev_read in ./dataset_${dataset_id}/*_*R2_*.fastq.gz; do
      if [[ -s $rev_read ]]; then 
        echo "cat rev reads: cat $rev_read >> ~{sample_name}_R2.fastq.gz" 
        cat $rev_read >> ~{sample_name}_R2.fastq.gz
      fi
    done
    echo "Lane Count: ${lane_count}"
  >>>
  output {
    File read1 = "~{sample_name}_R1.fastq.gz"
    File? read2 = "~{sample_name}_R2.fastq.gz"
  }
  runtime {
    docker: "quay.io/theiagen/basespace_cli:1.2.1"
    memory: "~{mem_size_gb} GB"
    cpu: CPUs
    disks: "local-disk ~{disk_size} SSD"
    preemptible: Preemptible
  }
}