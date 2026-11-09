/// Lệnh giọng nói đã được phân tích.
sealed class Command {
  const Command();
}

/// Dẫn đường tới vật có nhãn thuộc [labelsEn] (tên Việt: [nameVi]).
class NavigateTo extends Command {
  final Set<String> labelsEn;
  final String nameVi;
  const NavigateTo(this.labelsEn, this.nameVi);
}

class Describe extends Command {
  const Describe();
}

class Recap extends Command {
  const Recap();
}

class Stop extends Command {
  const Stop();
}

/// Tên vật được gọi nhưng model hiện tại không nhận ra.
class UnsupportedTarget extends Command {
  final String nameVi;
  const UnsupportedTarget(this.nameVi);
}

class Unknown extends Command {
  final String text;
  const Unknown(this.text);
}
