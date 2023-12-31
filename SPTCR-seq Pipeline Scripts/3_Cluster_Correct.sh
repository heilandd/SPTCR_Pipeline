#!/usr/bin/env bash
##### Argparse Scripts #####

# Use python's argparse module in shell scripts
#
# The function `argparse` parses its arguments using
# argparse.ArgumentParser; the parser is defined in the function's
# stdin.
#
# Executing ``argparse.bash`` (as opposed to sourcing it) prints a
# script template.
#
# https://github.com/nhoffman/argparse-bash
# MIT License - Copyright (c) 2015 Noah Hoffman

argparse(){
    argparser=$(mktemp 2>/dev/null || mktemp -t argparser)
    cat > "$argparser" <<EOF
from __future__ import print_function
import sys 
import argparse
import os


class MyArgumentParser(argparse.ArgumentParser):
    def print_help(self, file=None):
        """Print help and exit with error"""
        super(MyArgumentParser, self).print_help(file=file)
        sys.exit(1)

parser = MyArgumentParser(prog=os.path.basename("$0"),
            description="""$ARGPARSE_DESCRIPTION""")
EOF

    # stdin to this function should contain the parser definition
    cat >> "$argparser"

    cat >> "$argparser" <<EOF
args = parser.parse_args()
for arg in [a for a in dir(args) if not a.startswith('_')]:
    key = arg.upper()
    value = getattr(args, arg, None)

    if isinstance(value, bool) or value is None:
        print('{0}="{1}";'.format(key, 'yes' if value else ''))
    elif isinstance(value, list):
        print('{0}=({1});'.format(key, ' '.join('"{0}"'.format(s) for s in value)))
    else:
        print('{0}="{1}";'.format(key, value))
EOF

    # Define variables corresponding to the options if the args can be
    # parsed without errors; otherwise, print the text of the error
    # message.
    if python "$argparser" "$@" &> /dev/null; then
        eval $(python "$argparser" "$@")
        retval=0
    else
        python "$argparser" "$@"
        retval=1
    fi

    rm "$argparser"
    return $retval
}
##########################################
##### Argparse Options #####
ARGPARSE_DESCRIPTION="Pipeline to group & Correct T-Cell Receptor Reads generated by Oxford Nanopore Reads of Libraries prepared for 10X Genomics"
argparse "$@" <<EOF || exit 1

parser.add_argument('-n','--NAME',help="Name of Output Folder",default="-")
parser.add_argument('-i', '--INPUT_FASTQ', help="Specify the Path to (preprocessed) Fastq File",required=True)
parser.add_argument('-b', '--INPUT_IGB', help="Path to IgBlast.tsv. Use Full IgBlast Output from PreProcessed Reads for the grouping of TCR Reads.",required=True)
parser.add_argument('-o', '--OUTFOLDER', help="Specify the Directory for the Outputfolder, default = PWD", default="PWD")

parser.add_argument('-t','--THREADS',help="Number of Threads to use, default=2", default="2")

parser.add_argument('-lm','--LOWMEM',help="Set to True if Memory & Compute Intensive Parallel-Correction Step should be done sequentially to reduce System Pressure. default=False", default="False")

parser.add_argument('-rep', '--REPOSITORY', help="Specify the Location of the Repositroy Folder holding all References and scripts for SPTCR Seq,default,default=./",default="./")

parser.add_argument('-igb', '--IGBLAST', help="If True, the corrected Fastq is aligned with IgBLAST Following Correction. default=True",default="True")

parser.add_argument('-cln', '--CLEANUP', help="If True, created intermediate Files and Folders will be deleted. For Debugging you can set this to False. default=False",default="False")

parser.add_argument('-bc', '--BCUMI', help="Specify the path to the SAMPLENAME_barcode_umi.csv generated by the preprocessing pipeline. Defaults to OUTFOLDER/PreProcessing/SAMPLENAME_barcode_umi.csv",default="True")

parser.add_argument('-bars', '--BARCODES', help="Path to .tsv holding barcodes under Tissue, defaults to: ./Reference/Barcodes/visium_bc.tsv",default="visium_bc.tsv")

parser.add_argument('-grp', '--GROUPER', help="Grouper to be used by TCR_GROUPING_IGB.py for grouping the TCR Reads into Fastqs. Pick one or a combination of: locus,v_family, d_family, j_family, default= locus, v_family",default="locus,v_family")

EOF

################################################################
################## Define Variables BLOCK###########################
################################################################
if [ "${OUTFOLDER}" = "PWD" ];then
    OUTFOLDER="${PWD}"
    mkdir "${PWD}"/ClusterCorrect
    out="${OUTFOLDER}"
    OUTFOLDER="${PWD}"/ClusterCorrect
else
    mkdir "${OUTFOLDER}"/ClusterCorrect
    out="${OUTFOLDER}"
    OUTFOLDER="${OUTFOLDER}"/ClusterCorrect
fi 

if [ "${NAME}" = "-" ];then
    SAMPLE_NAME="$(basename "${INPUT_FASTQ}")"
    SAMPLE_NAME="$(cut -d'.' -f1 <<<"${SAMPLE_NAME}")"_$(date +%d_%Y)
else
    SAMPLE_NAME="${NAME}"
fi 



### Log Folder ####
mkdir "${OUTFOLDER}"/LOGS
LOGS="${OUTFOLDER}"/LOGS

### Timestamp Function ###

timestamp() {
    date +"%Y-%m-%d : %H-%M-%S" # current time
    }

STARTTIME=$(date +%s)

### ProgressBar Function ###
# 1.1 Input is currentState($1) and totalState($2)
function ProgressBar {
# Process data
    let _progress=(${1}*100/${2}*100)/100
    let _done=(${_progress}*4)/10
    let _left=40-$_done
# Build progressbar string lengths
    _fill=$(printf "%${_done}s")
    _empty=$(printf "%${_left}s")

# 1.2 Build progressbar strings and print the ProgressBar line
# 1.2.1 Output example:                           
# 1.2.1.1 Progress : [########################################] 100%
printf "\rProgress : [${_fill// /#}${_empty// /-}] ${_progress}%%"

}
_start=1

### Grouping Variables for TCR Fastq Splitting
echo "Using: ${GROUPER} as Grouper"

### Rattle Path
RATTLE_PATH="${REPOSITORY}"/TOOLS/RATTLE

### For TCR Annotation Summay
DEMUX_SUMMARY="${REPOSITORY}"/SCRIPTS/demultiplex_summarize.py
BARCODE_UMI_FILE="${out}"/PreProcessing/Demultiplexing_"${SAMPLE_NAME}"/"${SAMPLE_NAME}"_barcode_umi.csv


### For Barcode Demultiplexing

if [ "${BARCODES}" = "visium_bc.tsv" ];then
    BARCODES="${REPOSITORY}"/Reference/Barcodes/visium_bc.tsv
    
else
    BARCODES="${BARCODES}"
fi 


################################################################
################## Cluster BLOCK #######################
################################################################

echo " :::: Clustering Reads by VJ Arrangement ::::"

mkdir "${OUTFOLDER}"/IGB_CLUSTERS

python "${REPOSITORY}"/SCRIPTS/TCR_GROUPING_IGB.py \
    --IGB "${INPUT_IGB}" \
    --INPUT_FASTQ "${INPUT_FASTQ}" \
    --GROUPER "${GROUPER}" \
    --OUT "${OUTFOLDER}"/IGB_CLUSTERS 

IGB_CLUSTERS="${OUTFOLDER}"/IGB_CLUSTERS


#### For Progressbar Function
_end=$( find "${IGB_CLUSTERS}" -type f | wc -l)

################################################################
################## CORRECTION BLOCK #######################
################################################################
mkdir "${OUTFOLDER}"/CORRECTION
mkdir "${OUTFOLDER}"/CORRECTION/RATTLE_CLUSTERS
RATTLE_CLUSTERS_OUT="${OUTFOLDER}"/CORRECTION/RATTLE_CLUSTERS

mkdir "${OUTFOLDER}"/CORRECTION/RATTLE_CORRECT
RATTLE_CORRECT_OUT="${OUTFOLDER}"/CORRECTION/RATTLE_CORRECT

mkdir "${OUTFOLDER}"/CORRECTION/CORRECTED_MERGE
CORRECTED_MERGE="${OUTFOLDER}"/CORRECTION/CORRECTED_MERGE

mkdir "${LOGS}"/Rattle_Clustering 
mkdir "${LOGS}"/Rattle_Correction
#--fastq \

if [ "${LOWMEM}" = False ]; then
    echo "$(timestamp)"
    echo " :::: Parallel Correcting Fastq. Memory intensive!! ::::"
    find "${IGB_CLUSTERS}" -type f |parallel --jobs 0 --bar \
            "
            mkdir '${RATTLE_CLUSTERS_OUT}'/{/.}
            '${RATTLE_PATH}'/rattle cluster \
                -i {} \
                -t ${THREADS} \
                -o '${RATTLE_CLUSTERS_OUT}'/{/.} \
                --iso \
                2> '${LOGS}'/Rattle_Clustering/{/.}_clust_stderr.txt

            mkdir '${RATTLE_CORRECT_OUT}'/{/.}
            '${RATTLE_PATH}'/rattle correct \
                -i {} \
                -c '${RATTLE_CLUSTERS_OUT}'/{/.}/clusters.out \
                -t ${THREADS} \
                -o '${RATTLE_CORRECT_OUT}'/{/.} \
                2> '${LOGS}'/Rattle_Correction/{/.}_corr_stderr.txt
            "
    echo "$(timestamp)"

else
    echo "$(timestamp)"
    echo " :::: Sequentially Correcting Fastq. Less Memory Intensive. ::::"
    number=${_start}
    for file in "${IGB_CLUSTERS}"/*.fastq 
    do  
        ProgressBar ${number} ${_end}
        file_name=${file##*/}
        mkdir "${RATTLE_CLUSTERS_OUT}"/"${file_name%.fastq}"
        "${RATTLE_PATH}"/rattle cluster \
            -i "${file}" \
            -t ${THREADS} \
            -o "${RATTLE_CLUSTERS_OUT}"/"${file_name%.fastq}" \
            --iso \
            2> "${LOGS}"/Rattle_Clustering/"${file_name%.fastq}"_clust_stderr.txt

        mkdir "${RATTLE_CORRECT_OUT}"/"${file_name%.fastq}"
        "${RATTLE_PATH}"/rattle correct \
            -i "${file}" \
            -c "${RATTLE_CLUSTERS_OUT}"/"${file_name%.fastq}"/clusters.out \
            -t ${THREADS} \
            -o "${RATTLE_CORRECT_OUT}"/"${file_name%.fastq}" \
            2> "${LOGS}"/Rattle_Correction/"${file_name%.fastq}"_corr_stderr.txt
        let number+=1
    done
    echo "$(timestamp)"
fi

echo " :::: Parallel Merge Corrected Fastqs ::::"
find "${RATTLE_CORRECT_OUT}" -type f -name "corrected.fq"|parallel --jobs 0 --bar "cat {} >> '${CORRECTED_MERGE}'/${SAMPLE_NAME}_corrected_merged.fastq"

echo " :::: Checking Fastq Integrity & renaming Corr Fastq ::::"
seqkit sana "${CORRECTED_MERGE}"/"${SAMPLE_NAME}"_corrected_merged.fastq -o "${CORRECTED_MERGE}"/"${SAMPLE_NAME}"_corrected_merged_sana.fastq 2> "${LOGS}"/seqkit_sana.txt

rm "${CORRECTED_MERGE}"/"${SAMPLE_NAME}"_corrected_merged.fastq
mv "${CORRECTED_MERGE}"/"${SAMPLE_NAME}"_corrected_merged_sana.fastq "${CORRECTED_MERGE}"/"${SAMPLE_NAME}"_corrected_merged.fastq

mv "${CORRECTED_MERGE}/${SAMPLE_NAME}_corrected_merged.fastq" "${OUTFOLDER}"/"${SAMPLE_NAME}"_corrected_merged.fastq
CORRECTED_MERGED_FASTQ="${OUTFOLDER}"/"${SAMPLE_NAME}"_corrected_merged.fastq

################################################################
################## Final IGB Query BLOCK #######################
################################################################

if [ ${IGBLAST} = "True" ]; then
    echo " :::: Quering corrected Fastq to IGB :::: "
    mkdir "${OUTFOLDER}"/IGB_Corrected
    mkdir "${OUTFOLDER}"/IGB_Corrected/TEMP_"${SAMPLE_NAME}"
    cd "${OUTFOLDER}"/IGB_Corrected

    pyir \
        -t fastq \
        --outfmt tsv \
        -m ${THREADS} \
        --pretty \
        --debug \
        -r TCR \
        -s human \
        --numV 1 \
        --numD 1 \
        --numJ 1 \
        --gzip False \
        --tmp_dir "${OUTFOLDER}"/IGB_Corrected/TEMP_"${SAMPLE_NAME}" \
        -o "${SAMPLE_NAME}"_corrected_IGB \
        "${CORRECTED_MERGED_FASTQ}" >"${LOGS}"/final_igb.txt

    echo " :::: Moving Output Files to the Front ::::"

    mv "${OUTFOLDER}"/IGB_Corrected/"${SAMPLE_NAME}"_corrected_IGB.tsv "${OUTFOLDER}"/"${SAMPLE_NAME}"_corrected_IGB.tsv
    IGBLAST_TABLE="${OUTFOLDER}"/"${SAMPLE_NAME}"_corrected_IGB.tsv

else 
    echo " :::: Not quering IgBlast as indicated ::::"
fi


if [ ${CLEANUP} = "True" ]; then
    echo " :::: Removing Intermediate Files ::::"


    ### Remove Created Working Directories
    rm -r "${OUTFOLDER}"/IGB_Corrected
    rm -r "${OUTFOLDER}"/CORRECTION
    
    rm -r "${IGB_CLUSTERS}"
    rm -r "${OUTFOLDER}"/CORRECTION/RATTLE_CORRECT
    rm -r "${OUTFOLDER}"/CORRECTION/RATTLE_CLUSTERS

else echo " :::: Keeping all Intermediate Files ::::"
fi
cd "${OUTFOLDER}"
if [ ${IGBLAST} = "True" ]; then
    echo " :::: Generate the VDj Annotation Summary of the Corrected Reads ::::"

    python "${DEMUX_SUMMARY}" \
        -igb "${IGBLAST_TABLE}" \
        -bc  "${BARCODE_UMI_FILE}" \
        --MOD "True" \
        --OUTN "corrected_igb_overview_igb" \
        -n "${SAMPLE_NAME}" \
        -o "${OUTFOLDER}" 

    echo " :::: Performing UMI Correction on Corrected Summary ::::"

    "${REPOSITORY}/SCRIPTS/umi_correct_output.py" \
        -igb "${OUTFOLDER}/${SAMPLE_NAME}_corrected_igb_overview_igb.csv" \
        -n "${SAMPLE_NAME}" \
        -outn 'CORRECTED_umi_corrected_count_table' \
        --BARCODES "${BARCODES}" \
        -O "${OUTFOLDER}" 

    ##########################
    echo " :::: Generate the VDj Annotation Summary of the Uncorrected Reads ::::"

    python "${DEMUX_SUMMARY}" \
        -igb "${INPUT_IGB}" \
        -bc  "${BARCODE_UMI_FILE}" \
        --MOD "True" \
        --OUTN "uncorrected_igb_overview_igb" \
        -n "${SAMPLE_NAME}" \
        -o "${OUTFOLDER}" 

    echo " :::: Performing UMI Correction on Uncorrected Summary ::::"

    "${REPOSITORY}/SCRIPTS/umi_correct_output.py" \
        -igb "${OUTFOLDER}/${SAMPLE_NAME}_uncorrected_igb_overview_igb.csv" \
        -n "${SAMPLE_NAME}" \
        -outn 'UNCORRECTED_umi_corrected_count_table' \
        --BARCODES "${BARCODES}" \
        -O "${OUTFOLDER}" 

    echo "Done with SPTCR-seq Correction Pipeline. Corrected IgBlast Overview File is in ${OUTFOLDER}/${SAMPLE_NAME}_(un)corrected_igb_overview_igb.csv, UMI Corrected Summary Counts are in ${OUTFOLDER}/${SAMPLE_NAME}_(UN)CORRECTED_umi_corrected_count_table.csv"

else 
    echo " :::: Generate the VDj Annotation Summary of the Uncorrected Reads ::::"

    python "${DEMUX_SUMMARY}" \
        -igb "${INPUT_IGB}" \
        -bc  "${BARCODE_UMI_FILE}" \
        --MOD "True" \
        --OUTN "uncorrected_igb_overview_igb" \
        -n "${SAMPLE_NAME}" \
        -o "${OUTFOLDER}" 

    echo " :::: Performing UMI Correction on Uncorrected Summary ::::"

    "${REPOSITORY}/SCRIPTS/umi_correct_output.py" \
        -igb "${OUTFOLDER}/${SAMPLE_NAME}_uncorrected_igb_overview_igb.csv" \
        -n "${SAMPLE_NAME}" \
        -outn 'uncorrected_umi_corrected_count_table' \
        -O "${OUTFOLDER}"

    echo " :::: Not quering IgBlast for corrected as indicated. Done with SPTCR-seq Correction Pipeline. ::::"
    exit
fi