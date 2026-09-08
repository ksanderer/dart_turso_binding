import 'dart:ffi';

@Native<Pointer<Void> Function()>(symbol: 'dtb_create')
external Pointer<Void> create();

@Native<Pointer<Char> Function(Pointer<Void>, Pointer<Char>)>(
  symbol: 'dtb_request',
)
external Pointer<Char> request(Pointer<Void> session, Pointer<Char> input);

@Native<Void Function(Pointer<Char>)>(symbol: 'dtb_free')
external void free(Pointer<Char> response);

@Native<Void Function(Pointer<Void>)>(symbol: 'dtb_destroy')
external void destroy(Pointer<Void> session);
