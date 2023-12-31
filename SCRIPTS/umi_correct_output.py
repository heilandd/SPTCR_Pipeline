#!/usr/bin/env python
import argparse
from random import sample
parser = argparse.ArgumentParser(description='Script to UMI Correct TCR Table generated by SPTCR-seq Pipeline')

parser.add_argument('-O','--OUT',help= "Path to Outfolder", required=False, default='./' )
parser.add_argument('-igb','--IGB',help="Path to IgBlast csv that should be UMI-corrected. IMPORTANT: Expects Columns: Locus, V, D, J, CDR3_aa, Spatial Barcode, UMI as generated by SPTCR-seq Pipeline",default="")
parser.add_argument('-bc','--BCOL',help="Name of the Barcode Column in the Input csv", required=False,default="Spatial Barcode" )
parser.add_argument('-umi','--UMICOL',help="Name of the UMI Column in the Input csv", required=False,default="UMI" )
parser.add_argument('-barc','--BARCODES',help="Path to .tsv holding barcodes under Tissue", required=False,default="./Reference/Barcodes/visium_bc.tsv" )
parser.add_argument('-n','--NAME',help="Name of the Pipeline. Defaults to fastq basename_date", required=False,default="" )
parser.add_argument('-outn','--OUTNAME',help="Extension to add to outfile", required=False,default="_umi_corrected_count_table" )
parser.add_argument('-d','--STRDIST',help="String Distance to use for UMI Clustering", default=2 )


args = parser.parse_args()

arg_vars = vars(args)
##################### Import Modules ############################
from umi_tools import UMIClusterer
from collections import defaultdict, Counter
import pandas as pd
from tqdm import tqdm
import os
from Bio.Seq import Seq

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
## Subsetting and Merging V,(D),J Columns to one
vdj=igb[igb['Locus'].isin(['TRB','TRD'])]
vdj=vdj.dropna(subset=['Locus','V','D','J','CDR3_aa'])
vdj[['Locus','V','D','J','CDR3_aa']]=vdj[['Locus','V','D','J','CDR3_aa']].astype(str)
vdj['TCR']=vdj[['Locus','V','D','J','CDR3_aa']].agg('___'.join,axis=1)
vdj=vdj[['TCR',barcode_col,umi_col]]

vj=igb[igb['Locus'].isin(['TRA','TRG'])]
vj=vj.dropna(subset=['Locus','V','J','CDR3_aa'])
vj[['Locus','V','J','CDR3_aa']]=vj[['Locus','V','J','CDR3_aa']].astype(str)
vj['TCR']=vj[['Locus','V','J','CDR3_aa']].agg('___'.join,axis=1)
vj=vj[['TCR',barcode_col,umi_col]]

## Grouping TCR Columns to one
vdj=vdj.groupby(['TCR','Spatial Barcode'])['UMI'].apply(list).reset_index(name='UMI List')
vdj['Uncorrected Count']=vdj.apply(lambda x: len(x['UMI List']),axis='columns')
vdj=vdj.sort_values(by='Uncorrected Count',ascending=False).reset_index(drop=True)

vj=vj.groupby(['TCR','Spatial Barcode'])['UMI'].apply(list).reset_index(name='UMI List')
vj['Uncorrected Count']=vj.apply(lambda x: len(x['UMI List']),axis='columns')
vj=vj.sort_values(by='Uncorrected Count',ascending=False).reset_index(drop=True)

#######################################################
##################### UMI Correcting ##################
clusterer = UMIClusterer(cluster_method="directional")

tcrs=pd.concat([vdj,vj])
tcrs=tcrs.reset_index(drop=True)

tcrs['UMI Corrected']=""
for index, row in tqdm(tcrs.iterrows()):
    if row['Uncorrected Count'] > 1:
        umi_bytes=[str.encode(umi) for umi in row['UMI List']]
        umis=dict(Counter(umi_bytes))
        clustered_umis = clusterer(umis, threshold=2)
        tcrs.loc[index,'UMI Corrected']=len(clustered_umis)
    else:
        tcrs.loc[index,'UMI Corrected']=1

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
tcrs=tcrs.set_index('Spatial Barcode')
rev_comp_tcrs=tcrs.merge(visium_bc_revcomp,left_index=True,right_on='Merge BC',how='inner').drop(columns=['Merge BC'])
rev_comp_tcrs=rev_comp_tcrs.rename(columns={'UMI Corrected':'UMI Corrected Reverse','Uncorrected Count':'Uncorrected Count Reverse'})

fwd_tcrs=tcrs.merge(visium_bc_fwd,left_index=True,right_on='Merge BC',how='inner').drop(columns=['Merge BC'])
fwd_tcrs=fwd_tcrs.rename(columns={'UMI Corrected':'UMI Corrected Forward','Uncorrected Count':'Uncorrected Count Forward'})

comp_tcrs=tcrs.merge(visium_bc_comp,left_index=True,right_on='Merge BC',how='inner').drop(columns=['Merge BC'])
comp_tcrs=comp_tcrs.rename(columns={'UMI Corrected':'UMI Corrected Complement','Uncorrected Count':'Uncorrected Count Complement'})

## Merge Tables & Correct Count
tcrs_clean_barcodes=pd.concat([rev_comp_tcrs,fwd_tcrs,comp_tcrs])
#print(tcrs_clean_barcodes['Direction'].value_counts())
tcrs_clean_barcodes['UMI Corrected']=tcrs_clean_barcodes[['UMI Corrected Forward','UMI Corrected Reverse','UMI Corrected Complement']].sum(axis=1)
tcrs_clean_barcodes['Uncorrected Count']=tcrs_clean_barcodes[['Uncorrected Count Forward','Uncorrected Count Reverse','Uncorrected Count Complement']].sum(axis=1)
tcrs_clean_barcodes=tcrs_clean_barcodes.drop(columns=['UMI Corrected Reverse','UMI Corrected Forward','UMI Corrected Complement','Uncorrected Count Reverse','Uncorrected Count Forward','Uncorrected Count Complement'])

tcrs_clean_barcodes=tcrs_clean_barcodes.groupby(['TCR','Spatial Barcode']).sum()
tcrs_clean_barcodes=tcrs_clean_barcodes.sort_values(by=['UMI Corrected'],ascending=False)
tcrs_clean_barcodes=tcrs_clean_barcodes.reset_index(drop=False)
tcrs=tcrs_clean_barcodes.copy()
del tcrs_clean_barcodes


#######################################################
##################### Revert Changes of TCR Col ##################

vdj=tcrs[(tcrs['TCR'].str.startswith('TRB'))|(tcrs['TCR'].str.startswith('TRD'))]
vdj[['Locus','V','D','J','CDR3_aa']]=vdj['TCR'].str.split('___',expand=True)
vdj=vdj.drop(columns=['TCR'])
#,'UMI List'

vj=tcrs[(tcrs['TCR'].str.startswith('TRA'))|(tcrs['TCR'].str.startswith('TRG'))]
vj[['Locus','V','J','CDR3_aa']]=vj['TCR'].str.split('___',expand=True)
vj=vj.drop(columns=['TCR'])
#,'UMI List'
vj['D']=''

tcrs=pd.concat([vdj,vj])
print(tcrs)

#######################################################
##################### Write File Out ##################

write_name=sample_name+"_{0}.csv".format(OUTNAME)
outpath=os.path.join(OUT,write_name)
tcrs.to_csv(outpath,index=False)