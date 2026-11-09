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
  // Lớp mới — chỉ có khi dùng model train riêng (xem training/classes.yaml)
  'pole': 'cột',
  'traffic sign': 'biển báo',
  'tree': 'cây',
  'branch': 'cành cây',
  'railing': 'lan can',
  'barrier': 'rào chắn',
  'vendor cart': 'xe hàng rong',
  'stairs': 'bậc thang', // model v1–v3 (chưa tách hướng)
  'stairs up': 'cầu thang đi lên',
  'stairs down': 'cầu thang đi xuống',
  'curb': 'mép vỉa hè',
  'pothole': 'ổ gà',
  'manhole': 'hố ga',
  'bollard': 'cọc chắn',
  'traffic cone': 'cọc giao thông',
  'hole': 'hố',
};

// Model COCO không nhận ra các nhãn mặt đất này; chỉ model v4 (smart_eye.tflite)
// có stairs up/down, curb, pothole, manhole. 'stairs' là nhãn của model v1–v3.
const _groundHazards = {
  'manhole',
  'pothole',
  'stairs',
  'stairs up',
  'stairs down',
  'curb',
  'hole',
};

/// Nguy hiểm mặt đất "nhẹ": gặp rất thường xuyên (mép vỉa hè) → tối đa chỉ
/// nhắc chú ý, không bao giờ hô "Dừng lại".
const mildGroundHazards = {'curb'};
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
  'umbrella', // model v4: ô dù / ô bán hàng che vỉa hè
  // Vật cố định của model v4. 'traffic sign' là cả biển + cột chôn trên vỉa hè
  // (khác 'stop sign' của COCO); 'vendor cart' thường đứng yên chiếm lối đi.
  'pole', 'traffic sign', 'tree', 'branch', 'railing', 'barrier',
  'vendor cart', 'bollard', 'traffic cone',
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

/// Classes the detector keeps. Traffic lights and stop signs are not
/// obstacles but are still worth mentioning in descriptions.
bool isDetectionRelevant(String labelEn) =>
    labelEn == 'traffic light' ||
    labelEn == 'stop sign' ||
    categoryOf(labelEn) != ObjectCategory.other;

/// Viết hoa chữ cái đầu câu
String capitalize(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
