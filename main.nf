
if (params.help) {
    exit 0, usageMessage()
}

checkInputParams()

reference = file(params.reference)
refdir = file(reference.getParent())
known     = file(params.known)
outdir    = params.out
chromosomes = refdir.name.contains('test-data-tiny') ? ['chr38'] : (1..38).collect {"chr${it}"} + 'chrX'

fastqFiles = Channel.fromFilePairs(params.fastqDir + '/*R{1,2}.fq.gz')
fastqFiles.into { fastq_qc; fastq_bwa }


infoMessage()


process fastqc {
    input:
        set val(key), file(fastqs) from fastq_qc

    output:
        file "*_fastqc.{zip,html}" into fastQCreport

    publishDir "out"


    script:
    """
    fastqc -q $fastqs
    """
}


process bwa {
    input:
        set val(key), file(fastqs) from fastq_bwa
        file refdir 
    output:
        set file("file.bam"), file("file.bam.bai") into mapped_reads

    publishDir "out"


    script:
    readGroup = "@RG\\tID:Sample_79162\\tSM:bar\\tPL:ILLUMINA"
    """
    [[ -e $refdir/${reference.baseName}.fa.bwt ]] || bwa index $refdir/${reference.getName()}
    bwa mem -t $task.cpus -M -R \'$readGroup\' $refdir/${reference.getName()} $fastqs |
        samtools sort --threads $task.cpus -m 4G > file.bam
    samtools index file.bam
    """
}


process gatk_realign {
    input:
        set file("file.bam"), file("file.bam.bai") from mapped_reads
        file refdir 
    output:
        file('name.intervals')
        set file('file.realigned.bam'), file('file.realigned.bai') into realigned_reads

    publishDir 'out'


    script:
    """
    java -jar /usr/GenomeAnalysisTK.jar \
        -I file.bam \
        -R $refdir/${reference.getName()} \
        -T RealignerTargetCreator \
        -o name.intervals

    java -jar /usr/GenomeAnalysisTK.jar \
        -I file.bam \
        -R $refdir/${reference.getName()} \
        -T IndelRealigner \
        -targetIntervals name.intervals \
        -o file.realigned.bam
    """
}


process mark_duplicates {
    input:
        set file('file.bam'), file('file.bam.bai') from realigned_reads
    output:
        set file('file.realigned.marked.bam'), file('file.realigned.marked.bai') into marked_reads

    publishDir 'out'


    script:
    """
    picard MarkDuplicates.jar \
        INPUT=file.bam \
        OUTPUT=file.realigned.marked.bam \
        METRICS_FILE=file.realigned.marked.metrics \
        VALIDATION_STRINGENCY=LENIENT

    picard BuildBamIndex.jar \
        INPUT=file.realigned.marked.bam \
        VALIDATION_STRINGENCY=LENIENT
    """
}


process quality_recalibration {
    input:
        set file('file.bam'), file('file.bam.bai') from marked_reads
        file known
    output:
        file('file.recal_data.table')
        file('file.post_recal_data.table')
        set file('file.recalibrated.bam'), file('file.recalibrated.bai') into recalibrated_bam
        file('file.recalibration_plots.pdf')

    publishDir 'out'


    script:
    """
    # Step 1 - We need a list of known sites otherwise, GATK will think all the
    #          real SNPs in our data are errors. Failure to remove real SNPs
    #          from the recalibration will result in globally lower quality
    #          scores
    java -jar /usr/GenomeAnalysisTK.jar \
        -T BaseRecalibrator \
        -I file.bam \
        -R $reference \
        -knownSites $known \
        -o file.recal_data.table \
        -rf BadCigar

    # Step 2
    java -jar /usr/GenomeAnalysisTK.jar \
        -T BaseRecalibrator \
        -I file.bam \
        -R $reference \
        -knownSites $known \
        -BQSR file.recal_data.table \
        -o file.post_recal_data.table

    # Step 3 - Create before and after plots
    java -jar /usr/GenomeAnalysisTK.jar \
        -T AnalyzeCovariates \
        -R $reference \
        -before file.recal_data.table \
        -after file.post_recal_data.table \
        -plots file.recalibration_plots.pdf

    # Step 4 - Base calibration
    java -jar /usr/GenomeAnalysisTK.jar \
        -T PrintReads \
        -I file.bam \
        -R $reference \
        -BQSR file.recal_data.table \
        -o file.recalibrated.bam
    """
}


recalibrated_bam.tap { recalibrated_bam_flagstats; recalibrated_bam_hsmetrics; recalibrated_bam_haplotype }


process flagstats {
    input:
        set file('file.bam'), file('file.bai') from recalibrated_bam_flagstats
    output:
        file('file.flagstat')

    publishDir 'out'


    script:
    """
    samtools flagstat file.bam > file.flagstat
    """
}


process haplotypeCaller {
    input:
        set file('file.bam'), file('file.bai') from recalibrated_bam_haplotype
        file refdir 
    output:
        file('file.g.vcf') into haplotype_caller


    script:
    """
    java -jar /usr/GenomeAnalysisTK.jar \
        -T HaplotypeCaller\
        -R $refdir/${reference.getName()} \
        -I file.bam \
        --emitRefConfidence GVCF \
        --variant_index_type LINEAR \
        --variant_index_parameter 128000 \
        -o file.g.vcf \
        -rf BadCigar
    """
}


process haplotypeCallerCompress {
    input:
        file('file.g.vcf') from haplotype_caller
    output:
        file('file.g.vcf.gz') into compress_haplocalled
        file('file.g.vcf.gz.tbi') into compress_haplocall_ix

    publishDir 'out'


    script:
    """
    bgzip file.g.vcf
    tabix file.g.vcf.gz
    """
}


process hsmetrics {
    input:
        set file('file.bam'), file('file.bai') from recalibrated_bam_hsmetrics
        file reference

    output:
        file('file.hybridd_selection_metrics')

    publishDir 'out'

    when: false

    script:
    """
    picard CalculateHsMetrics.jar \
        R=$reference \
        BAIT_INTERVALS=$bait \
        TARGET_INTERVALS=$target \
        INPUT=file.bam \
        OUTPUT=file.hybrid_selection_metrics \
        VALIDATION_STRINGENCY=LENIENT
    """
}

/* COMBINE GVCF
This needs to collect 150/200 samples from samples.list
Unsure how to get those
Script also runs one per chromosome it seems, could use each
*/

compress_haplocalled
  .collect()
  .set { collect_haplovcfs }

compress_haplocall_ix
  .collect()
  .set { collect_haplovcfsix }

process gVCFCombine {

    input:
    file refdir 
    file vcfs from collect_haplovcfs
    file indexed_vcfs from collect_haplovcfsix
    each chrom from chromosomes
     
    output:
    file "${chrom}-group1.vcf" into combined

    script:
    """
    java -Xmx7g -jar /usr/GenomeAnalysisTK.jar \
        -T CombineGVCFs \
        -V ${vcfs.join(' -V ')} \
        -R $refdir/${reference.getName()} \
        -o ${chrom}-group1.vcf -L $chrom
    """
}


process bgZipCombinedGVCF {

    input:
    file combined_gvcf from combined

    output:
    file "${combined_gvcf}.gz" into compressed_comb_gvcf

    """
    bgzip $combined_gvcf
    """
}

compressed_comb_gvcf
  .subscribe { println it }
/*
process genotype {
    input:
        set file('file.vcf.gz'), file('file.vcf.gz.tbi') from input
        file reference
    output:
        file 'genotyped.vcf.gz'


    script:
    """
    java -Xmx7g -jar /usr/GenomeAnalysisTK.jar \
        -T GenotypeGVCFs \
        -R $reference \
        -V samples.list \
        -o all_samples_genotyping.vcf.gz
    """
}
*/


////////////////////////////////////////////////////////////////////////////////
// FUNCTIONS                                                                  //
////////////////////////////////////////////////////////////////////////////////


def checkInputParams() {
    // Check required parameters and display error messages
    boolean fatal_error = false
    if ( ! params.fastqDir ) {
        log.warn("You need to provide a fastqDir (--fastqDir)")
        fatal_error = true
    }
    if ( ! params.reference ) {
        log.warn("You need to provide a genome reference (--reference)")
        fatal_error = true
    }
    if ( ! params.known ) {
        log.warn("You need to provide a file of known sites (--known)")
        fatal_error = true
    }

    if (fatal_error) {
        log.warn "See --help for more information"
        exit 1
    }
}

def usageMessage() {
    log.info """\
    Usage:
        nextflow run main.nf --fastqDir <directory>
    Options:
        --fastqDir <Dir>
           Directory containing fastq samples (.fq.gz)
        --reference <file>
           Genome reference file (has to be indexed)
        --known <file>
           File with known sites for quality calibration.
        --out <dir>
           Directory for output files
    """
}

def infoMessage() {
    log.info """\
*** K9 WGS Pipeline ***
Configuration environemnt:
    Out directory: $params.out
    """
}
