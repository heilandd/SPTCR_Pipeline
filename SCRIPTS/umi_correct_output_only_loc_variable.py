#!/usr/bin/env python
import argparse
from random import sample
parser = argparse.ArgumentParser(description='Script to UMI Correct by Locus & Variable Segment generated by SPTCR-seq Pipeline')

parser.add_argument('-O','--OUT',help= "Path to Outfolder", required=False, default='./' )
parser.add_argument('-igb','--IGB',help="Path to IgBlast csv that should be UMI-corrected. IMPORTANT: Expects Columns: Locus, V, D, J, CDR3_aa, Spatial Barcode, UMI as generated by SPTCR-seq Pipeline",default="")
parser.add_argument('-bc','--BCOL',help="Name of the Barcode Column in the Input csv", required=False,default="Spatial Barcode" )
parser.add_argument('-umi','--UMICOL',help="Name of the UMI Column in the Input csv", required=False,default="UMI" )
parser.add_argument('-n','--NAME',help="Name of the Pipeline. Defaults to fastq basename_date", required=False,default="" )
parser.add_argument('-outn','--OUTNAME',help="Extension to add to outfile", required=False,default="_umi_corrected_count_table" )
parser.add_argument('-d','--STRDIST',help="String Distance to use for UMI Clustering", default=2 )
parser.add_argument('-barc','--BARCODES',help="Path to .tsv holding barcodes under Tissue", required=False,default="./Reference/Barcodes/visium_bc.tsv" )


args = parser.parse_args()

arg_vars = vars(args)

###################### Example ################################
    #"${REPOSITORY}/SCRIPTS/umi_correct_output_only_loc.py" \
    #    -igb "${OUTFOLDER}/${SAMPLE_NAME}_uncorrected_igb_overview_igb.csv" \
    #    -n "${SAMPLE_NAME}" \
    #    -outn 'uncorrected_only_loc_umi_corrected_count_table' \
    #    -O "${OUTFOLDER}"


##################### Import Modules ############################
from umi_tools import UMIClusterer
from collections import defaultdict, Counter
import pandas as pd
from tqdm import tqdm
import os

### Disable Setting Value on Copy Warning
pd.options.mode.chained_assignment = None

#######################################################
#################### Variables ########################
OUT=str(arg_vars["OUT"])
sample_name=arg_vars["NAME"]
read_dir=arg_vars["IGB"]
string_dist=arg_vars["STRDIST"]
barcode_col=arg_vars["BCOL"]
umi_col=arg_vars["UMICOL"]
OUTNAME=arg_vars["OUTNAME"]
BARCODES=arg_vars["BARCODES"]
#######################################################
############ Summarizing and Preparing DF #############

## Reading in IGB
igb=pd.read_csv(read_dir)

### Preparing Data
igb=igb.dropna(subset=['Locus','Variable'])
igb=igb[['Locus',barcode_col,umi_col]]
igb=igb.groupby(['Locus','Spatial Barcode','Variable'])['UMI'].apply(list).reset_index(name='UMI List')
igb['Uncorrected Count']=igb.apply(lambda x: len(x['UMI List']),axis='columns')
igb=igb.sort_values(by='Uncorrected Count',ascending=False).reset_index(drop=True)

#######################################################
##################### UMI Correcting ##################
clusterer = UMIClusterer(cluster_method="directional")

igb=igb.reset_index(drop=True)

igb['UMI Corrected']=""

for index, row in tqdm(igb.iterrows()):
    if row['Uncorrected Count'] > 1:
        umi_bytes=[str.encode(umi) for umi in row['UMI List']]
        umis=dict(Counter(umi_bytes))
        clustered_umis = clusterer(umis, threshold=2)
        igb.loc[index,'UMI Corrected']=len(clustered_umis)
    else:
        igb.loc[index,'UMI Corrected']=1
        
igb=igb[["Locus","Spatial Barcode","Uncorrected Count","UMI Corrected"]]
print(igb)

####### Combine Counts of Complement and Reverse Complement Barcode

visium_bc=pd.read_csv(BARCODES,names=['Spatial Barcode'])

## Get Permutations
visium_bc['Spatial Barcode']=visium_bc['Spatial Barcode']

visium_bc_fwd=visium_bc.copy()
visium_bc_fwd['Merge BC']=visium_bc_fwd['Spatial Barcode']
visium_bc_fwd['Direction']='Forward'

visium_bc_revcomp=visium_bc.copy()
visium_bc_revcomp['Merge BC']=visium_bc['Spatial Barcode'].apply(lambda x: str(Seq(x).reverse_complement()))
visium_bc_revcomp['Direction']='RevComp'

visium_bc_comp=visium_bc.copy()
visium_bc_comp['Merge BC']=visium_bc['Spatial Barcode'].apply(lambda x: str(Seq(x).complement()))
visium_bc_comp['Direction']='Comp'

## Combine Counts
igb=igb.set_index('Spatial Barcode')
rev_comp_igb=igb.merge(visium_bc_revcomp,left_index=True,right_on='Merge BC',how='inner').drop(columns=['Merge BC'])
rev_comp_igb=rev_comp_igb.rename(columns={'UMI Corrected':'UMI Corrected Reverse','Uncorrected Count':'Uncorrected Count Reverse'})

fwd_igb=igb.merge(visium_bc_fwd,left_index=True,right_on='Merge BC',how='inner').drop(columns=['Merge BC'])
fwd_igb=fwd_igb.rename(columns={'UMI Corrected':'UMI Corrected Forward','Uncorrected Count':'Uncorrected Count Forward'})

comp_igb=igb.merge(visium_bc_comp,left_index=True,right_on='Merge BC',how='inner').drop(columns=['Merge BC'])
comp_igb=comp_igb.rename(columns={'UMI Corrected':'UMI Corrected Complement','Uncorrected Count':'Uncorrected Count Complement'})

## Merge Tables & Correct Count
igb_clean_barcodes=pd.concat([rev_comp_igb,fwd_igb,comp_igb])
print(igb_clean_barcodes['Direction'].value_counts())
igb_clean_barcodes['UMI Corrected']=igb_clean_barcodes[['UMI Corrected Forward','UMI Corrected Reverse','UMI Corrected Complement']].sum(axis=1)
igb_clean_barcodes['Uncorrected Count']=igb_clean_barcodes[['Uncorrected Count Forward','Uncorrected Count Reverse','Uncorrected Count Complement']].sum(axis=1)
igb_clean_barcodes=igb_clean_barcodes.drop(columns=['UMI Corrected Reverse','UMI Corrected Forward','UMI Corrected Complement','Uncorrected Count Reverse','Uncorrected Count Forward','Uncorrected Count Complement'])

igb_clean_barcodes=igb_clean_barcodes.groupby(['TCR','Spatial Barcode']).sum()
igb_clean_barcodes=igb_clean_barcodes.sort_values(by=['UMI Corrected'],ascending=False)
igb_clean_barcodes=igb_clean_barcodes.reset_index(drop=False)
igb=igb_clean_barcodes.copy()
del igb_clean_barcodes

#######################################################
##################### Write File Out ##################
#out_path=os.path(OUT)
write_name=sample_name+"_{0}.csv".format(OUTNAME)
outpath=os.path.join(OUT,write_name)
igb.to_csv(outpath,index=False)