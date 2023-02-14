version 1.0

import "https://raw.githubusercontent.com/aofarrel/clockwork-wdl/2.0.1/workflows/refprep-TB.wdl" as clockwork_ref_prepWF
import "https://raw.githubusercontent.com/aofarrel/clockwork-wdl/2.6.1/tasks/combined_decontamination.wdl" as clckwrk_combonation
import "https://raw.githubusercontent.com/aofarrel/clockwork-wdl/2.6.1/tasks/variant_call_one_sample.wdl" as clckwrk_var_call
import "https://raw.githubusercontent.com/aofarrel/SRANWRP/v1.1.7/tasks/pull_fastqs.wdl" as sranwrp_pull
import "https://raw.githubusercontent.com/aofarrel/SRANWRP/v1.1.7/tasks/processing_tasks.wdl" as sranwrp_processing
import "https://raw.githubusercontent.com/aofarrel/usher-sampled-wdl/0.0.2/usher_sampled.wdl" as build_treesWF
import "https://raw.githubusercontent.com/aofarrel/parsevcf/1.1.0/vcf_to_diff.wdl" as diff
import "https://raw.githubusercontent.com/aofarrel/fastqc-wdl/main/fastqc.wdl" as fastqc

workflow myco {
	input {
		File biosample_accessions
		File typical_tb_masked_regions

		Float   bad_data_threshold = 0.05
		Boolean decorate_tree = false
		Boolean fastqc_on_timeout = false
		File?   input_tree
		Boolean less_scattering = false
		Int     min_coverage = 10
		File?   ref_genome_for_tree_building
		Int     subsample_cutoff = 450
		Int     subsample_seed = 1965
		Int     timeout_decontam_part1 =  20
		Int     timeout_decontam_part2 =  15
		Int     timeout_variant_caller = 120
		Boolean tar_fqs = false
	}

	parameter_meta {
		biosample_accessions: "File of BioSample accessions to pull, one accession per line"
		bad_data_threshold: "If a diff file has higher than this percent (0.5 = 50%) bad data, don't include it in the tree"
		decorate_tree: "Should usher, taxonium, and NextStrain trees be generated? Requires input_tree and ref_genome"
		fastqc_on_timeout: "If true, fastqc one read from a sample when decontamination times out (see timeout_decontam)"
		input_tree: "Base tree to use if decorate_tree = true"
		less_scattering: "(deprecated) Create less VMs by combining all decontamination jobs"
		min_coverage: "Positions with coverage below this value will be masked in diff files"
		ref_genome_for_tree_building: "Ref genome, ONLY used for building trees, NOT variant calling"
		subsample_cutoff: "If a fastq file is larger than than size in MB, subsample it with seqtk (set to -1 to disable)"
		subsample_seed: "Seed used for subsampling with seqtk"
		timeout_decontam_part1: "Discard any sample that is still running in clockwork map_reads after this many minutes (set to -1 to never timeout)"
		timeout_decontam_part2: "Discard any sample that is still running in clockwork rm_contam after this many minutes (set to -1 to never timeout)"
		timeout_variant_caller: "Discard any sample that is still running in clockwork variant_call_one_sample after this many minutes (set to -1 to never timeout)"
		tar_fqs: "(deprecated) Tarball fastqs after pulling them"
		typical_tb_masked_regions: "Bed file of regions to mask when making diff files"
	}

	call clockwork_ref_prepWF.ClockworkRefPrepTB

	call sranwrp_processing.extract_accessions_from_file as get_sample_IDs {
		input:
			accessions_file = biosample_accessions
	}

	scatter(biosample_accession in get_sample_IDs.accessions) {
		call sranwrp_pull.pull_fq_from_biosample as pull {
			input:
				biosample_accession = biosample_accession,
				tar_outputs = tar_fqs,
				subsample_cutoff = subsample_cutoff,
				subsample_seed = subsample_seed
		} # output: pull.fastqs OR pull.tarball_fastqs
		if(length(pull.fastqs)>1) {
    		Array[File] paired_fastqs=select_all(pull.fastqs)
  		}
	}

	call sranwrp_processing.cat_strings as cat_reports {
		input:
			strings = pull.results
	}

	if(!less_scattering) {
		Array[Array[File]] pulled_fastqs   = select_all(paired_fastqs)
		scatter(pulled_fastq in pulled_fastqs) {
			call clckwrk_combonation.combined_decontamination_single as per_sample_decontam {
				input:
					unsorted_sam = true,
					reads_files = pulled_fastq,
					tarball_ref_fasta_and_index = ClockworkRefPrepTB.tar_indexd_dcontm_ref,
					ref_fasta_filename = "ref.fa",
					timeout_map_reads = timeout_decontam_part1,
					timeout_decontam = timeout_decontam_part2
			}

			if(defined(per_sample_decontam.decontaminated_fastq_1)) {
			# This region only executes if decontaminated fastqs exist.
			# We can use this to coerce File? into File by using a
			# select_first() where the first element is the File? we know
			# absolutely must exist, and the second element is bogus
	    		File real_decontaminated_fastq_1=select_first([
	    			per_sample_decontam.decontaminated_fastq_1, 
	    				biosample_accessions])
	    		File real_decontaminated_fastq_2=select_first(
	    			[per_sample_decontam.decontaminated_fastq_2, 
	    				biosample_accessions])

				call clckwrk_var_call.variant_call_one_sample_simple as varcall_with_array {
					input:
						ref_dir = ClockworkRefPrepTB.tar_indexd_H37Rv_ref,
						reads_files = [real_decontaminated_fastq_1, real_decontaminated_fastq_2],
						timeout = timeout_variant_caller
				} # output: varcall_with_array.vcf_final_call_set, varcall_with_array.mapped_to_ref
			}

		}

		Array[File] minos_vcfs_=select_all(varcall_with_array.vcf_final_call_set)
		Array[File] bams_to_ref_=select_all(varcall_with_array.mapped_to_ref)


		scatter(vcfs_and_bams in zip(bams_to_ref_, minos_vcfs_)) {
			call diff.make_mask_and_diff as make_mask_and_diff_ {
				input:
					bam = vcfs_and_bams.left,
					vcf = vcfs_and_bams.right,
					min_coverage = min_coverage,
					tbmf = typical_tb_masked_regions
			}
		}

		if(fastqc_on_timeout) {
			if(length(per_sample_decontam.check_this_fastq)>1) {
				call fastqc.FastqcWF {
					input:
						fastqs = select_all(per_sample_decontam.check_this_fastq)
				}
			}
		}
	}

	if(less_scattering) {
		Array[File] tarball_paired_fastqs=select_all(pull.tarball_fastqs)
		call clckwrk_combonation.combined_decontamination_multiple as decontaminate_many_samples {
			input:
				unsorted_sam = true,
				tarballs_of_read_files = tarball_paired_fastqs,
				tarball_ref_fasta_and_index = ClockworkRefPrepTB.tar_indexd_dcontm_ref,
				ref_fasta_filename = "ref.fa"
		} # output: decontaminate_many_samples.tarballs_of_decontaminated_reads
		

		scatter(one_sample in decontaminate_many_samples.tarballs_of_decontaminated_reads) {
			call clckwrk_var_call.variant_call_one_sample_verbose as varcall_with_tarballs {
				input:
					ref_dir = ClockworkRefPrepTB.tar_indexd_H37Rv_ref,
					tarball_of_reads_files = one_sample
			} # output: varcall_with_tarballs.vcf_final_call_set, varcall_with_tarballs.mapped_to_ref
		}

		Array[File] minos_vcfs=select_all(varcall_with_tarballs.vcf_final_call_set)
		Array[File] bams_to_ref=select_all(varcall_with_tarballs.mapped_to_ref)


		scatter(vcfs_and_bams in zip(bams_to_ref, minos_vcfs)) {
			call diff.make_mask_and_diff as make_mask_and_diff {
				input:
					bam = vcfs_and_bams.left,
					vcf = vcfs_and_bams.right,
					min_coverage = min_coverage,
					tbmf = typical_tb_masked_regions
			}
		}

	}

	if(decorate_tree) {
		call build_treesWF.usher_sampled_diff_to_taxonium as trees {
			input:
				diffs = select_first([make_mask_and_diff.diff, make_mask_and_diff_.diff]),
				i = input_tree,
				ref = ref_genome_for_tree_building,
				coverage_reports = select_first([make_mask_and_diff.report, make_mask_and_diff_.report]),
				bad_data_threshold = bad_data_threshold
		}
	}

	output {
		Array[File] minos = select_first([minos_vcfs, minos_vcfs_])
		Array[File] masks = select_first([make_mask_and_diff.mask_file, make_mask_and_diff_.mask_file])
		Array[File] diffs = select_first([make_mask_and_diff.diff, make_mask_and_diff_.diff])
		File? tax_tree = trees.taxonium_tree
		Array[File]? fastqc_reports = FastqcWF.reports
	}
}
