String? validateEmployeeNumber(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return 'Escribe el número de empleado.';
  if (!RegExp(r'^[0-9]{1,30}$').hasMatch(text)) {
    return 'Usa únicamente dígitos (0 a 9), máximo 30.';
  }
  return null;
}

String? validateEmployeeName(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return 'Escribe el nombre.';
  if (text.length > 120 ||
      !RegExp(
        r"^[\p{L}\p{M}]+(?:[ '\-’][\p{L}\p{M}]+)*$",
        unicode: true,
      ).hasMatch(text)) {
    return 'Usa letras, espacios, guiones o apóstrofos; sin números.';
  }
  return null;
}
