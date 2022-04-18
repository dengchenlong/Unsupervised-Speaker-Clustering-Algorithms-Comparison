#!/usr/bin/env bash
# Copyright   2022   Nankai University (Author: Chenlong Deng)
# Apache 2.0.
#
# 此配方对AMI语料库中的mix-headset录音进行说话人分割聚类。
# 这个配方使用了已知的SAD。
# 此配方演示了使用i-vector和聚类方法（AHC、VBx、谱聚类）进行说话人分割聚类。

. ./cmd.sh
. ./path.sh
set -euo pipefail

stage=7
diarizer_stage=2  # 1: extract vectors; 2: score; 3: cluster
nj=10
decode_nj=9

train_cmd="run.pl"
test_sets="dev test"
AMI_DIR=/data/dcl/ami-mix-headset

GMMs=2048  # 512~2048
score_type=plda  # plda/cossim
diarizer_type=spectral  # ahc/spectral/vbx

. utils/parse_options.sh

# 下载AMI语料库，需要14GB左右，注意脚本中的数据集存放路径。
if [ $stage -le 1 ]; then
  [ -d $AMI_DIR ] || local/ami_download.sh
fi

# 准备数据文件存放目录。
if [ $stage -le 2 ]; then
  # 下载数据集分割和参考。
  if ! [ -d AMI-diarization-setup ]; then
    git clone https://github.com/BUTSpeechFIT/AMI-diarization-setup
  fi

  for dataset in train $test_sets; do
    echo "$0: preparing $dataset set.."
    mkdir -p data/"$dataset"
    # 从会议lists和已知的SAD标签准备wav.scp和segments文件。
    # 将所有参考RTTM文件合到一个文件中。
    local/prepare_data.py --sad-labels-dir AMI-diarization-setup/only_words/labs/"${dataset}" \
      AMI-diarization-setup/lists/"${dataset}".meetings.txt \
      $AMI_DIR data/"$dataset"
    cat AMI-diarization-setup/only_words/rttms/"${dataset}"/*.rttm \
      > data/"${dataset}"/rttm.annotation

    awk '{print $1,$2}' data/"$dataset"/segments > data/"$dataset"/utt2spk
    utils/utt2spk_to_spk2utt.pl data/"$dataset"/utt2spk > data/"$dataset"/spk2utt
    utils/fix_data_dir.sh data/"$dataset"
  done
fi

# 提取MFCC音频特征。
if [ $stage -le 3 ]; then
  for dataset in train $test_sets; do
    steps/make_mfcc.sh --mfcc-config conf/mfcc.conf --nj 15 --cmd "$train_cmd" data/"$dataset" exp/"$dataset"_mfcc exp/"$dataset"_mfcc
    steps/compute_vad_decision.sh --nj 10 --cmd "$train_cmd" data/"$dataset" exp/"$dataset"_vad exp/"$dataset"_vad
    utils/fix_data_dir.sh data/"$dataset"
  done
fi

if [ $stage -le 4 ]; then
  echo "$0: training ubm and i-vector extractor"
  # 训练对角ubm
  sid/train_diag_ubm.sh --nj $nj --cmd "$train_cmd" \
    data/train ${GMMs} exp/train_diag_ubm
  # 训练全ubm
  sid/train_full_ubm.sh --nj $nj --cmd "$train_cmd" data/train \
    exp/train_diag_ubm exp/train_full_ubm
  # 训练i-vector模型
  sid/train_ivector_extractor.sh --nj 2 --cmd "$train_cmd" \
    exp/train_full_ubm/final.ubm data/train exp/ivector_extractor
  utils/fix_data_dir.sh data/train
fi

if [ $stage -le 5 ]; then
  echo "$0: extracting i-vector"
  # 提取i-vector
  diarization/extract_ivectors.sh --cmd "$train_cmd" --nj 9 \
    exp/ivector_extractor data/train exp/train_ivector
fi

# 训练PLDA模型。
if [ $stage -le 6 ]; then
  echo "$0: training PLDA model"
  # 计算平均矢量使待评估矢量居中。
  $train_cmd exp/train_plda_ivector/log/compute_mean.log \
    ivector-mean scp:exp/train_ivector/ivector.scp \
    exp/train_plda_ivector/mean.vec || exit 1;

  # 训练PLDA模型
  $train_cmd exp/train_plda_ivector/log/plda.log \
    ivector-compute-plda ark:exp/train_ivector/spk2utt \
    "ark:ivector-subtract-global-mean scp:exp/train_ivector/ivector.scp ark:- |\
     transform-vec exp/train_ivector/transform.mat ark:- ark:- |\
      ivector-normalize-length ark:-  ark:- |" \
    exp/train_plda_ivector/plda || exit 1;
  
  cp exp/train_plda_ivector/mean.vec exp/ivector_extractor/
  cp exp/train_ivector/transform.mat exp/ivector_extractor/
  cp exp/train_plda_ivector/plda exp/ivector_extractor/
fi

if [ $stage -le 7 ]; then
  for datadir in ${test_sets}; do
    ref_rttm=data/${datadir}/rttm.annotation

    diarize_nj=$(wc -l < "data/$datadir/wav.scp")
    nj=$((decode_nj>diarize_nj ? diarize_nj : decode_nj))
    local/diarize.sh --nj $nj --cmd "$train_cmd" --stage $diarizer_stage \
      --embedding_type ivector --score_type $score_type --cluster_type $diarizer_type \
      exp/ivector_extractor data/"${datadir}" exp/"${datadir}"_"${diarizer_type}"_ivector

    # 使用md-eval.pl评估RTTM
    rttm_affix=
    if [ $diarizer_type == "vbx" ]; then
      rttm_affix=".vb"
    fi
    md-eval.pl -r "$ref_rttm" -s exp/"${datadir}"_"${diarizer_type}"_ivector/rttm${rttm_affix} > result_ivector_"$score_type"_"$diarizer_type"_"$datadir"
  done
fi
