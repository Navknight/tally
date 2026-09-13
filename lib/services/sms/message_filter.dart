/// What a message is, decided before anything tries to read money out of it.
///
/// Extraction alone is not a filter: promotional and request messages quote
/// amounts too, so a parser that trusts any currency figure will happily book
/// "Rs.5000 cashback offer" as income. Everything runs through here first.
enum MessageClass { transactional, otp, promotional, request, personal }

const _otpMarkers = [
  'otp',
  'one time password',
  'one-time password',
  'verification code',
  'security code',
  'do not share',
  'never share',
];

const _promotionalMarkers = [
  'offer',
  'cashback up to',
  'discount',
  'sale',
  'coupon',
  'win ',
  'winner',
  'congratulations',
  'apply now',
  'lowest price',
  'pre-approved',
  'eligible for a loan',
  'loan offer',
  'click here',
  't&c apply',
  'unsubscribe',
  'limited period',
  'buy now',
];

/// Collect requests look exactly like debits apart from these phrases, and
/// booking one would invent a transaction the user never made.
const _requestMarkers = [
  'has requested',
  'is requesting',
  'payment request',
  'collect request',
  'requesting payment',
  'requests rs',
  'ignore if already paid',
  'will be debited',
  'will be deducted',
  'is due',
  'due on',
  'due date',
  'autopay',
  'mandate',
  'e-mandate',
  'payment reminder',
  'kindly pay',
  'please pay',
  'overdue',
];

const _transactionMarkers = [
  'debited',
  'credited',
  'spent',
  'paid',
  'sent',
  'received',
  'withdrawn',
  'deposited',
  'transferred',
  'purchase',
  'debit',
  'credit',
  'txn',
  'transaction',
  'upi',
  'imps',
  'neft',
  'rtgs',
];

MessageClass classifyMessage(String body) {
  final text = body.toLowerCase();
  // OTPs first: they are the one class that also carries "do not share" style
  // wording that would otherwise read as promotional.
  if (_otpMarkers.any(text.contains)) return MessageClass.otp;
  if (_requestMarkers.any(text.contains)) return MessageClass.request;
  final transactional = _transactionMarkers.any(text.contains);
  // A promotional message that also says "debited" is rare; a transaction alert
  // mentioning "offer" in its tail is not, so a real transaction verb wins
  // unless the message opens promotionally.
  if (_promotionalMarkers.any(text.contains) && !transactional)
    return MessageClass.promotional;
  if (!transactional) return MessageClass.personal;
  return MessageClass.transactional;
}
