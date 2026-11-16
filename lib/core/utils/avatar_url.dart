/// X appends a size suffix to avatar filenames (`_normal`, `_bigger`,
/// `_200x200`, ...). Stripping it yields the original upload, which is what
/// "highest quality" should mean everywhere in the UI.
final RegExp _avatarSizeSuffix =
    RegExp(r'_(normal|bigger|mini|small|medium|large|[0-9]+x[0-9]+)(?=\.[a-zA-Z]+$)');

String? highResAvatarUrl(String? url) {
  if (url == null || url.isEmpty) return null;
  return url.replaceAll(_avatarSizeSuffix, '');
}
