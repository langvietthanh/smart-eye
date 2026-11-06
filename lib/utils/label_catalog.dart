import '../models/scene_info.dart';

/// Map nhãn tiếng Anh → tiếng Việt cho TTS.
/// Có cả tên COCO kiểu cũ (motorbike, sofa...) lẫn kiểu mới (motorcycle, couch...)
/// và các lớp đặc thù VN (hố ga, bậc thang) để dùng khi fine-tune model riêng (mức 🥈).
const Map<String, String> labelVi = {
  'person': 'người',
  'bicycle': 'xe đạp',
  'car': 'xe ô tô',
  'motorbike': 'xe máy',
  'motorcycle': 'xe máy',
  'aeroplane': 'máy bay',
  'airplane': 'máy bay',
  'bus': 'xe buýt',
  'train': 'tàu hỏa',
  'truck': 'xe tải',
  'boat': 'thuyền',
  'traffic light': 'cột đèn giao thông',
  'fire hydrant': 'trụ cứu hỏa',
  'stop sign': 'biển báo',
  'parking meter': 'cột đỗ xe',
  'bench': 'ghế băng',
  'bird': 'chim',
  'cat': 'mèo',
  'dog': 'chó',
  'horse': 'ngựa',
  'sheep': 'cừu',
  'cow': 'bò',
  'elephant': 'voi',
  'bear': 'gấu',
  'zebra': 'ngựa vằn',
  'giraffe': 'hươu cao cổ',
  'backpack': 'ba lô',
  'umbrella': 'ô dù',
  'handbag': 'túi xách',
  'tie': 'cà vạt',
  'suitcase': 'vali',
  'sports ball': 'quả bóng',
  'skateboard': 'ván trượt',
  'bottle': 'chai',
  'cup': 'cốc',
  'bowl': 'bát',
  'chair': 'ghế',
  'sofa': 'ghế sofa',
  'couch': 'ghế sofa',
  'pottedplant': 'chậu cây',
  'potted plant': 'chậu cây',
  'bed': 'giường',
  'diningtable': 'bàn',
  'dining table': 'bàn',
  'toilet': 'bồn cầu',
  'tvmonitor': 'ti vi',
  'tv': 'ti vi',
  'laptop': 'laptop',
  'mouse': 'chuột máy tính',
  'keyboard': 'bàn phím',
  'cell phone': 'điện thoại',
  'microwave': 'lò vi sóng',
  'oven': 'lò nướng',
  'sink': 'bồn rửa',
  'refrigerator': 'tủ lạnh',
  'book': 'sách',
  'clock': 'đồng hồ',
  'vase': 'bình hoa',
  // Lớp đặc thù VN — chỉ có khi dùng model fine-tune riêng
  'manhole': 'hố ga',
  'pothole': 'ổ gà',
  'stairs': 'bậc thang',
  'hole': 'hố',
};

// Model COCO hiện tại không nhận ra hố ga, ổ gà, bậc thang, hố;
// các nhãn này chỉ dùng khi đổi sang model khác.
const _groundHazards = {'manhole', 'pothole', 'stairs', 'hole'};
const _vehicles = {
  'bicycle',
  'car',
  'motorbike',
  'motorcycle',
  'bus',
  'train',
  'truck',
};
const _obstacles = {
  'bench',
  'chair',
  'sofa',
  'couch',
  'pottedplant',
  'potted plant',
  'diningtable',
  'dining table',
  'bed',
  'toilet',
  'tvmonitor',
  'tv',
  'refrigerator',
  'fire hydrant',
  // Traffic signs/lights identify the sign or light, not a ground-level pole.
  'parking meter', 'suitcase',
};
const _animals = {
  'dog',
  'cat',
  'horse',
  'cow',
  'sheep',
  'elephant',
  'zebra',
  'giraffe',
};

/// Các nhãn gần như chắc là nhận nhầm trong môi trường người khiếm thị di chuyển;
/// được lọc bỏ trước khi đưa vào tracker.
const ignoredLabels = {
  'elephant',
  'giraffe',
  'zebra',
  'bear',
  'aeroplane',
  'airplane',
  'boat',
};

ObjectCategory categoryOf(String labelEn) {
  if (labelEn == 'person') return ObjectCategory.person;
  if (_groundHazards.contains(labelEn)) return ObjectCategory.groundHazard;
  if (_vehicles.contains(labelEn)) return ObjectCategory.vehicle;
  if (_obstacles.contains(labelEn)) return ObjectCategory.obstacle;
  if (_animals.contains(labelEn)) return ObjectCategory.animal;
  return ObjectCategory.other;
}

/// Viết hoa chữ cái đầu câu
String capitalize(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
