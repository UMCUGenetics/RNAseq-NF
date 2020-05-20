include HaplotypeCaller from '../NextflowModules/GATK/4.1.3.0/HaplotypeCaller.nf' params (mem:params.haplotypecaller.mem,
                                                                                          genome_fasta:params.genome_fasta,
                                                                                          optional:params.haplotypecaller.toolOptions )
include VariantFiltration from '../NextflowModules/GATK/4.1.3.0/VariantFiltration.nf' params(mem:params.variantfiltration.mem,,
                                                                                             genome_fasta:params.genome_fasta,
                                                                                             optional: params.variantfiltration.toolOptions )
include MergeVCFs as MergeVCF from '../NextflowModules/GATK/4.1.3.0/MergeVCFs.nf' params( mem: params.mergevcf.mem )
include BaseRecalibrationTable from '../NextflowModules/GATK/4.1.3.0/BaseRecalibrationTable.nf' params(mem:params.baserecalibrator.mem,
												       optional:params.baserecalibrator.toolOptions,
												       genome_known_sites:params.genome_known_sites,
                                                                                                       genome_fasta:params.genome_fasta)
include GatherBaseRecalibrationTables from '../NextflowModules/GATK/4.1.3.0/GatherBaseRecalibrationTables.nf' params(mem:params.gatherbaserecalibrator.mem)
include BaseRecalibration from '../NextflowModules/GATK/4.1.3.0/BaseRecalibration.nf' params(mem:params.applybqsr.mem,
                                                                                             genome_fasta: params.genome_fasta)
include MergeBams from '../NextflowModules/Sambamba/0.6.8/MergeBams.nf' params(mem:params.mergebams.mem)
include SplitIntervals from '../NextflowModules/GATK/4.1.3.0/SplitIntervals.nf' params(optional: params.splitintervals.toolOptions)
include SplitNCigarReads from '../NextflowModules/GATK/4.1.3.0/SplitNCigarReads.nf' params(genome_fasta:params.genome_fasta)                     
include CreateIntervalList from '../NextflowModules/Utils/CreateIntervaList.nf' params(params)

workflow gatk_germline_snp_indel {
    take:
      run_id
      bam_dedup
    main:
        //Check for Scatter intervallist
        if ( params.scatter_interval_list ) {
            scatter_interval_list = Channel
              .fromPath( params.scatter_interval_list, checkIfExists: true)
              .ifEmpty { exit 1, "Scatter intervals not found: ${params.scatter_interval_list}"}
        } else if ( !params.scatter_interval_list ) {
            genome_index = Channel
                .fromPath(params.genome_fasta + '.fai', checkIfExists: true)
                .ifEmpty { exit 1, "Fai file not found: ${params.genome_fasta}.fai"}
            genome_dict = Channel
                .fromPath( params.genome_dict, checkIfExists: true)
                .ifEmpty { exit 1, "Genome dictionary not found: ${params.genome_dict}"}
            CreateIntervalList( genome_index, genome_dict )
            scatter_interval_list = CreateIntervalList.out.genome_interval_list
        }
        //Scatter intervals
        SplitIntervals( 'no-break', scatter_interval_list)
        scatter_intervals = SplitIntervals.out.flatten()
        //NCigar split
        SplitNCigarReads(bam_dedup)
        final_bam = SplitNCigarReads.out.bam_file
        //Perform BQSR
        if ( params.runGATK4_BQSR ) {
            BaseRecalibrationTable(final_bam.combine(scatter_intervals))
            GatherBaseRecalibrationTables(BaseRecalibrationTable.out.groupTuple())
            //Perform BQSR
            BaseRecalibration(
              final_bam
                .combine(GatherBaseRecalibrationTables.out, by:0)
                .combine(scatter_intervals)
            )
            //Merge recalibrated bams
            MergeBams(
              BaseRecalibration.out
                .groupTuple()
                .map{ [it[0],it[2],it[3]] }
            )
            //Set final bam file to recalibrated bam
            final_bam = MergeBams.out
        }
        //      
        HaplotypeCaller(final_bam.combine(scatter_intervals))
        //Merge scattered vcf chunks/sample
        MergeVCF(
          HaplotypeCaller.out.groupTuple(by:[0]).map{
            sample_id, intervals, gvcfs, idxs, interval_files ->
            [sample_id, gvcfs, idxs]
          }
        )
        //Filter raw vcf files/sample
        VariantFiltration( MergeVCF.out.map{
          sample_id, vcfs, idxs -> [sample_id, run_id, "RNA", vcfs, idxs] }
        )
      
    emit:
      bam_recal = MergeBams.out	
      vcf_filter = VariantFiltration.out
      bqsr_table = GatherBaseRecalibrationTables.out

}