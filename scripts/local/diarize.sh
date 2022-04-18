#!/bin/bash
# Copyright   2019   David Snyder
#             2020   Desh Raj
#             2022   Chenlong Deng

# Apache 2.0.
#
# This script takes an input directory that has a segments file (and
# a feats.scp file), and performs diarization on it. The VBx clustering method uses BUTs
# Bayesian HMM-based diarization model. A first-pass of AHC is performed
# first followed by VB-HMM.

stage=0
nj=10
cmd="run.pl"
embedding_type="xvector"
score_type="plda"
cluster_type="spectral"

echo "$0 $@"  # Print the command line for logging
if [ -f path.sh ]; then . ./path.sh; fi
. parse_options.sh || exit 1;
if [ $# != 3 ]; then
  echo "Usage: $0 <model-dir> <in-data-dir> <out-dir>"
  echo "e.g.: $0 exp/xvector_nnet_1a  data/dev exp/dev_diarization"
  echo "Options: "
  echo "  --nj <nj>                                        # number of parallel jobs."
  echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
  echo "  --stage <diarizer stage>"
  echo "  --embedding_type <embedding type>                # xvector/ivector"
  echo "  --score_type <score type>                        # plda/cossim"
  echo "  --cluster_type <cluster type>                    # ahc/spectral/vbx, vbx is only used for xvectors."
  exit 1;
fi

model_dir=$1
data_in=$2
out_dir=$3

name=`basename $data_in`

if [ $embedding_type == "xvector" ]; then
  for f in $data_in/feats.scp $data_in/segments $model_dir/plda \
    $model_dir/final.raw $model_dir/extract.config; do
    [ ! -f $f ] && echo "$0: No such file $f" && exit 1;
  done

  echo "$0: computing features for x-vector extractor"
  utils/fix_data_dir.sh data/${name}
  rm -rf data/${name}_cmn
  local/nnet3/xvector/prepare_feats.sh --nj $nj --cmd "$cmd" \
    data/$name data/${name}_cmn exp/${name}_cmn
  cp data/$name/segments exp/${name}_cmn/
  utils/fix_data_dir.sh data/${name}_cmn
elif [ $embedding_type == "ivector" ]; then
  for f in $data_in/feats.scp $data_in/segments $model_dir/plda \
    $model_dir/final.ubm; do
    [ ! -f $f ] && echo "$0: No such file $f" && exit 1;
  done
  [ $cluster_type == "vbx" ] && echo "$0: vbx is only used for xvectors." && exit 1;
else
  echo "$0: No such embedding type $embedding_type" && exit 1;
fi

if [ $stage -le 1 ]; then
  echo "$0: extracting ${embedding_type}s for all segments"
  if [ $embedding_type == "xvector" ]; then
    diarization/nnet3/xvector/extract_xvectors.sh --cmd "$cmd" --nj $nj \
      --window 1.5 --period 0.75 --apply-cmn false --min-segment 0.5 \
      $model_dir data/${name}_cmn $out_dir/xvectors_${name}
  elif [ $embedding_type == "ivector" ]; then
    diarization/extract_ivectors.sh --cmd "$cmd" --nj $nj \
      exp/ivector_extractor data/${name} $out_dir/ivectors_${name}
  fi
fi

# Perform scoring
if [ $stage -le 2 ]; then
  # Perform scoring on all pairs of segments for each recording.
  echo "$0: performing $score_type scoring between all pairs of ${embedding_type}s"
  if [ $score_type == "cossim" ]; then
    if [ $embedding_type == "xvector" ]; then
      diarization/score_cossim.sh --cmd "$cmd" --nj $nj \
        $out_dir/${embedding_type}s_${name} $out_dir/${embedding_type}s_${name}/cossim_scores
    elif [ $embedding_type == "ivector" ]; then
      local/score_cossim.sh --cmd "$cmd" --nj $nj \
        $out_dir/${embedding_type}s_${name} $out_dir/${embedding_type}s_${name}/cossim_scores
    fi
  elif [ $score_type == "plda" ]; then
    if [ $embedding_type == "xvector" ]; then
      diarization/nnet3/xvector/score_plda.sh --cmd "$cmd" --nj $nj \
        --target-energy 0.1 \
        $model_dir/ $out_dir/${embedding_type}s_${name} $out_dir/${embedding_type}s_${name}/plda_scores
    elif [ $embedding_type == "ivector" ]; then
      diarization/score_plda.sh --cmd "$cmd" --nj $nj \
        $model_dir/  $out_dir/${embedding_type}s_${name} $out_dir/${embedding_type}s_${name}/plda_scores
    fi
  fi
fi

if [ $stage -le 3 ]; then
  case "${cluster_type}" in
    "ahc")
      echo "$0: performing ahc using ${score_type} scores"
      diarization/cluster.sh --cmd "$cmd" --nj $nj \
        --stage 0 --rttm-channel 1 --threshold 0.1 \
        $out_dir/${embedding_type}s_${name}/${score_type}_scores $out_dir
      echo "$0: wrote RTTM to output directory ${out_dir}"
    ;;
    "spectral")
      echo "$0: performing spectral clustering using ${score_type} scores"
      diarization/scluster.sh --cmd "$cmd" --nj $nj \
        --rttm-channel 1 --rttm-affix "$rttm_affix" \
        $out_dir/${embedding_type}s_${name}/${score_type}_scores $out_dir
      echo "$0: wrote RTTM to output directory ${out_dir}"
    ;;
    "vbx")
      echo "$0: performing ahc using $score_type scores (threshold tuned on dev)"
      diarization/cluster.sh --cmd "$cmd" --nj $nj \
        --rttm-channel 1 --threshold 0.1 \
        $out_dir/${embedding_type}s_${name}/${score_type}_scores $out_dir
      echo "$0: performing VB-HMM on top of first-pass AHC"
      diarization/vb_hmm_xvector.sh --nj $nj --rttm-channel 1 \
        --loop-prob 0.5 --fa 0.05 \
        $out_dir $out_dir/${embedding_type}s_${name} $model_dir/plda
      echo "$0: wrote RTTM to output directory ${out_dir}"
    ;;
    *)
      echo "$0: No such cluster type $cluster_type" && exit 1
    ;;
  esac
fi

