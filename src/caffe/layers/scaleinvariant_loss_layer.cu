#include <vector>

#include "caffe/layers/scaleinvariant_loss_layer.hpp"
#include "caffe/util/math_functions.hpp"

namespace caffe {



template <typename Dtype>
__global__ void Forward_gpu_kernel(
		 const int nthreads,
		 const Dtype* const data_label,
		 Dtype* data_diff,
		 Dtype* bad_pixel_data,
		 const int num,
		 const int channels,
		 const int height,
		 const int width,
		 const Dtype max_label,
		 const Dtype min_label){
	CUDA_KERNEL_LOOP(index, nthreads){
		const int n = index / height;
		const int h = index % height;

		const int data_offset = (n*channels*height+h)*width;
		const int bad_pixel_idx = index;
		const int interval = height * width;

		// Iter the width and channels
		for (int w = 0; w < width; w++){
			// Iter the channels
			int err_counter = 0;
			for (int c = 0; c < channels; c++){
				const int idx = data_offset + c * interval + w;
				Dtype dataval = data_label[idx];

				if (dataval > max_label){
					err_counter++;
				}else if(dataval < min_label){
					err_counter++;
				}
			}

			// Only if all channels invalid, the pixel will be considered
			// as invalid
			if(err_counter == channels){
				bad_pixel_data[bad_pixel_idx] += channels;
				for (int c = 0; c < channels; c++){
					const int idx = data_offset + c * interval + w;
					data_diff[idx] = 0;
				}
			}
		}
	}
}


template <typename Dtype>
__global__ void Backward_gpu_kernel(
		const int nthreads,
		const Dtype* const diff_data,
		Dtype* bottom_diff,
		const Dtype* const vecValidPixelNum_data,
		const Dtype* const vecSum_data,
		const int num,
		const int channels,
		const int height,
		const int width,
		const int sign,
		const int valid_pixel_num,
		const Dtype delta,
		const Dtype loss_weight){

	CUDA_KERNEL_LOOP(index, nthreads){
		const int n = index / height / channels;
		const int c = (index / height) % channels;
		const int h = index % height;

		const int data_offset = ((n*channels + c)*height + h)*width;

		// bottom diff = sign * (w1 * diff - w2)
		// Calc the w1
		const Dtype w1 = Dtype(1) / Dtype(valid_pixel_num);
		// Calc the w2
		const Dtype valid_sum = vecSum_data[n];
		const Dtype valid_num = vecValidPixelNum_data[n];
		const Dtype w2 = valid_sum * delta / num / valid_num / valid_num;

		for(int w = 0; w < width; w++){
			bottom_diff[data_offset+w] = sign * loss_weight * (w1 * diff_data[data_offset+w] - w2);
		}
	}
}

template <typename Dtype>
void ScaleInvariantLossLayer<Dtype>::Forward_gpu(const vector<Blob<Dtype>*>& bottom,
    const vector<Blob<Dtype>*>& top) {
  int count = bottom[0]->count();
  caffe_gpu_sub(
      count,
      bottom[0]->gpu_data(),
      bottom[1]->gpu_data(),
      diff_.mutable_gpu_data());

  Dtype* data_diff = diff_.mutable_gpu_data();
  Dtype* vecValidPixelNum_data = vecValidPixelNum_.mutable_cpu_data();
  Dtype* vecSum_data = vecSum_.mutable_cpu_data();
  const Dtype* data_label = bottom[1]->gpu_data();
  const int num = bottom[0]->num();
  const int channels = bottom[0]->channels();
  const int height = bottom[0]->height();
  const int width = bottom[0]->width();
  // Set the number of the kernel]
  const int num_kernels = num * height;
  // Set the bad_pixel_ buffer to 0
  Dtype* bad_pixel_data = bad_pixel_.mutable_gpu_data();
  caffe_gpu_set(bad_pixel_.count(), Dtype(0), bad_pixel_data);
  
    // Find the bad pixel and alter the diff
  if(is_use_bad_pixel_ == true){
	  Forward_gpu_kernel<Dtype><<<CAFFE_GET_BLOCKS(num_kernels), CAFFE_CUDA_NUM_THREADS>>>(
			  num_kernels,
			  data_label,
			  data_diff,
			  bad_pixel_data,
			  num,
			  channels,
			  height,
			  width,
			  max_val_,
			  min_val_);
  }
  // The pixel number per image
  Dtype pixel_num = bottom[0]->count(1);
  Dtype bad_pixel_count;
  // Calc the whole valid pixel number
  if(is_adjust_pixel_num_){
	  caffe_gpu_asum(bad_pixel_.count(), bad_pixel_data, &bad_pixel_count);
	  valid_pixel_num_ = count - bad_pixel_count;
  }else{
	  valid_pixel_num_ = count;
  }

  // Calc the each image's valid pixel number in minibatch
  for (int n = 0; n < diff_.num(); n++){
	  if(is_adjust_pixel_num_){
		  Dtype val;
		  int offset = bad_pixel_.offset(n);
		  caffe_gpu_asum(height, bad_pixel_data + offset, &val);
		  vecValidPixelNum_data[n] = pixel_num - val;
	  }else{
		  vecValidPixelNum_data[n] = pixel_num;
	  }
  }

  Dtype dot;
  caffe_gpu_dot(count, diff_.gpu_data(), diff_.gpu_data(), &dot);
  Dtype loss = dot / valid_pixel_num_ / Dtype(2);

  // Calc the second term of the loss
  for (int n = 0; n < bottom[0]->num(); n++){
	  const Dtype* cdata_diff = diff_.cpu_data() + diff_.offset(n);
	  Dtype valid_num = vecValidPixelNum_data[n];
	  Dtype vecSum = caffe_cpu_sum(pixel_num, cdata_diff);
	  vecSum_data[n] = vecSum;
	  loss -= vecSum_data[n] * vecSum_data[n] / valid_num / valid_num / bottom[0]->num() * delta_ / Dtype(2);
  }

  top[0]->mutable_cpu_data()[0] = loss;
  // DLOG(INFO) << "valid pixel num:" << valid_pixel_num_ <<" Loss:" << loss;
}

template <typename Dtype>
void ScaleInvariantLossLayer<Dtype>::Backward_gpu(const vector<Blob<Dtype>*>& top,
    const vector<bool>& propagate_down, const vector<Blob<Dtype>*>& bottom) {
  for (int i = 0; i < 2; ++i) {
    if (propagate_down[i]) {
      const Dtype sign = (i == 0) ? 1 : -1;
//      const Dtype alpha = sign * top[0]->cpu_diff()[0] / bottom[i]->num();
//      caffe_gpu_axpby(
//          bottom[i]->count(),              // count
//          alpha,                              // alpha
//          diff_.gpu_data(),                   // a
//          Dtype(0),                           // beta
//          bottom[i]->mutable_gpu_diff());  // b
//    }
	const Dtype* diff_data = diff_.gpu_data();
	const Dtype* vecValidPixelNum_data = vecValidPixelNum_.gpu_data();
	const Dtype* vecSum_data = vecSum_.gpu_data();
	Dtype* bottom_diff = bottom[i]->mutable_gpu_diff();
	const int num = bottom[i]->num();
	const int channels = bottom[i]->channels();
	const int height = bottom[i]->height();
	const int width = bottom[i]->width();

	const int num_kernels = num * channels * height;
	Backward_gpu_kernel<Dtype><<<CAFFE_GET_BLOCKS(num_kernels), CAFFE_CUDA_NUM_THREADS>>>(
			num_kernels,
			diff_data,
			bottom_diff,
			vecValidPixelNum_data,
			vecSum_data,
			num,
			channels,
			height,
			width,
			sign,
			valid_pixel_num_,
			delta_,
			top[0]->cpu_diff()[0]);


  }
}
}

INSTANTIATE_LAYER_GPU_FUNCS(ScaleInvariantLossLayer);

}  // namespace caffe
