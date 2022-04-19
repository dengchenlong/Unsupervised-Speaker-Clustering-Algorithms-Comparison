#!/bin/bash

# 这个脚本需要一个segments文件（和一个feats文件），并对其进行分割聚类。VBx聚类方法使用BUT的
# 基于贝叶斯隐马尔可夫分割聚类模型。执行VB-HMM之前需要执行一次AHC。

# 配置参数。
stage=0
nj=10
cmd="run.pl"
embedding_type="xvector"
score_type="plda"
cluster_type="spectral"
target_energy=0.1
threshold_ahc=0.1
threshold_vbx=0.1
loop_prob=0.5
fa=0.05
fb=1
min_neighbors=3
window=1.5
period=0.75
apply_cmn=false
min_segment=0.5
# 配置参数。

echo "$0 $@"  # 打印命令行作为记录
if [ -f path.sh ]; then . ./path.sh; fi
. parse_options.sh || exit 1;
if [ $# != 3 ]; then
  echo "Usage: $0 <model-dir> <in-data-dir> <out-dir>"
  echo "e.g.: $0 exp/xvector_nnet_1a  data/dev exp/dev_diarization"
  echo "Options: "
  echo "  --nj <nj>                                        # 并行工作数。"
  echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # 规定工作方式。"
  echo "  --stage <diarizer stage>"
  echo "  --embedding_type <embedding type>                # xvector/ivector"
  echo "  --score_type <score type>                        # plda/cossim"
  echo "  --cluster_type <cluster type>                    # ahc/spectral/vbx, vbx只用于x-vector。"
  echo "  --target_energy <target energy|0.1>"
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

  echo "$0: 计算用于输入x-vector模型的音频特征。"
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
  [ $cluster_type == "vbx" ] && echo "$0: vbx只用于x-vector。" && exit 1;
else
  echo "$0: 没有 $embedding_type 嵌入码类型。" && exit 1;
fi

if [ $stage -le 1 ]; then
  echo "$0: 提取所有语音片段的${embedding_type}嵌入码。"
  if [ $embedding_type == "xvector" ]; then
    diarization/nnet3/xvector/extract_xvectors.sh --cmd "$cmd" --nj $nj \
      --window $window --period $period --apply-cmn $apply_cmn --min-segment $min_segment \
      $model_dir data/${name}_cmn $out_dir/xvectors_${name}
  elif [ $embedding_type == "ivector" ]; then
    diarization/extract_ivectors.sh --cmd "$cmd" --nj $nj \
      exp/ivector_extractor data/${name} $out_dir/ivectors_${name}
  fi
fi

# 执行打分。
if [ $stage -le 2 ]; then
  # 对每个录音中的每对语音片段进行相似度打分。
  echo "$0: 对每对 ${embedding_type} 嵌入码执行 $score_type 相似度打分。"
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
        --target-energy $target_energy \
        $model_dir/ $out_dir/${embedding_type}s_${name} $out_dir/${embedding_type}s_${name}/plda_scores
    elif [ $embedding_type == "ivector" ]; then
      diarization/score_plda.sh --cmd "$cmd" --nj $nj \
        --target-energy $target_energy \
        $model_dir/  $out_dir/${embedding_type}s_${name} $out_dir/${embedding_type}s_${name}/plda_scores
    fi
  fi
fi

if [ $stage -le 3 ]; then
  case "${cluster_type}" in
    "ahc")
      echo "$0: 用 ${score_type} 相似度评分进行ahc。"
      diarization/cluster.sh --cmd "$cmd" --nj $nj \
        --stage 0 --rttm-channel 1 --threshold $threshold_ahc \
        $out_dir/${embedding_type}s_${name}/${score_type}_scores $out_dir
      echo "$0: 将RTTM文件写入到输出文件夹 ${out_dir}。"
    ;;
    "spectral")
      echo "$0: 用 ${score_type} 相似度评分进行谱聚类。"
      diarization/scluster.sh --cmd "$cmd" --nj $nj \
        --rttm-channel 1 --rttm-affix "$rttm_affix" --min_neighbors $min_neighbors \
        $out_dir/${embedding_type}s_${name}/${score_type}_scores $out_dir
      echo "$0: 将RTTM文件写入到输出文件夹 ${out_dir}。"
    ;;
    "vbx")
      echo "$0: 用 ${score_type} 相似度评分进行ahc (在验证集上调整 threshold)。"
      diarization/cluster.sh --cmd "$cmd" --nj $nj \
        --rttm-channel 1 --threshold $threshold_vbx \
        $out_dir/${embedding_type}s_${name}/${score_type}_scores $out_dir
      echo "$0: 在一轮AHC的结果上执行 VB-HMM 。"
      diarization/vb_hmm_xvector.sh --nj $nj \
        --rttm-channel 1 --loop-prob $loop_prob --fa $fa --fb $fb\
        $out_dir $out_dir/${embedding_type}s_${name} $model_dir/plda
      echo "$0: 将RTTM文件写入到输出文件夹 ${out_dir}。"
    ;;
    *)
      echo "$0: 没有 $cluster_type 聚类类型。" && exit 1
    ;;
  esac
fi

