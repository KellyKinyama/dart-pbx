import 'package:flutter/material.dart';

/// Color tokens lifted from the InnovateAsterisk Browser-Phone stylesheets
/// ([Phone/phone.css], [phone.light.css], [phone.dark.css]). They give the
/// app the same recognisable softphone look — blue accent, green answer/dial,
/// red hangup, presence dots, and chat bubble colors.
abstract final class BPColors {
  // Brand
  static const Color primary = Color(0xFF3478F3); // accent blue
  static const Color primaryDark = Color(0xFF416493); // header / pill nav
  static const Color buttonHoverDark = Color(0xFF333333);

  // Call-action buttons
  static const Color answer = Color(0xFF059609); // .answerButton
  static const Color answerHover = Color(0xFF0AA80F);
  static const Color dial = Color(0xFF25962F); // light .dialButtonsDial
  static const Color dialDark = Color(0xFF067D0F); // dark .dialButtonsDial
  static const Color hangup = Color(0xFFDC0000); // .hangupButton
  static const Color hangupHover = Color(0xFFFF1B1B);

  // Buddy active/holding line indicators
  static const Color activeCall = Color(0xFF40BD3F); // border-left active
  static const Color holdingCall = Color(0xFF999999); // border-left holding
  static const Color lineIcon = Color(0xFFCC9009); // .lineIcon background

  // Presence dots (.dotOnline / .dotOffline / .dotRinging / .dotInUse / …)
  static const Color presenceOnline = Color(0xFF3EB13E);
  static const Color presenceOffline = Color(0xFF666666);
  static const Color presenceRinging = Color(0xFFFF7300);
  static const Color presenceInUse = Color(0xFFB40202);
  static const Color presenceDnd = Color(0xFFFF6600);
  static const Color presenceReady = Color(0xFF3FBD3F);
  static const Color presenceOnHold = Color(0xFF99FD99);
  static const Color presenceFailed = Color(0xFFC70000);

  // Chat bubbles (.theirChatMessageText / .ourChatMessageText)
  static const Color theirBubbleLight = Color(0xFFECF7E6); // mint
  static const Color theirBubbleDark = Color(0xFF2C423A);
  static const Color ourBubbleLight = Color(0xFFF1F9FF); // light blue
  static const Color ourBubbleDark = Color(0xFF2B3842);

  // Stream backdrop (.streamSectionBackground)
  static const Color streamBgLight = Color(0xFFEFEADC);
  static const Color streamBgDark = Color(0xFF292929);

  // Buddy selection (.buddySelected)
  static const Color buddySelectedLight = Color(0xFFE1E1E1);
  static const Color buddySelectedDark = Color(0xFF404040);

  // Buddy active call row (.buddyActiveCall)
  static const Color buddyActiveLight = Color(0xFFEEEEEE);
  static const Color buddyActiveDark = Color(0xFF333333);
  static const Color buddyHoldLight = Color(0xFFC8C8C8);
  static const Color buddyHoldDark = Color(0xFF292929);

  // Page surfaces
  static const Color pageLight = Color(0xFFF6F6F6);
  static const Color pageDark = Color(0xFF222222);
}

/// Strongly-typed, theme-aware wrapper exposed via [ThemeExtension] so any
/// widget can reach into the Browser-Phone palette without conditionals.
@immutable
class BrowserPhoneColors extends ThemeExtension<BrowserPhoneColors> {
  const BrowserPhoneColors({
    required this.answer,
    required this.hangup,
    required this.dial,
    required this.activeCall,
    required this.holdingCall,
    required this.lineIcon,
    required this.presenceOnline,
    required this.presenceOffline,
    required this.presenceRinging,
    required this.presenceInUse,
    required this.presenceOnHold,
    required this.theirBubble,
    required this.theirBubbleText,
    required this.ourBubble,
    required this.ourBubbleText,
    required this.streamBackground,
    required this.buddySelected,
    required this.buddyActive,
    required this.buddyHold,
  });

  final Color answer;
  final Color hangup;
  final Color dial;
  final Color activeCall;
  final Color holdingCall;
  final Color lineIcon;
  final Color presenceOnline;
  final Color presenceOffline;
  final Color presenceRinging;
  final Color presenceInUse;
  final Color presenceOnHold;
  final Color theirBubble;
  final Color theirBubbleText;
  final Color ourBubble;
  final Color ourBubbleText;
  final Color streamBackground;
  final Color buddySelected;
  final Color buddyActive;
  final Color buddyHold;

  static const BrowserPhoneColors light = BrowserPhoneColors(
    answer: BPColors.answer,
    hangup: BPColors.hangup,
    dial: BPColors.dial,
    activeCall: BPColors.activeCall,
    holdingCall: BPColors.holdingCall,
    lineIcon: BPColors.lineIcon,
    presenceOnline: BPColors.presenceOnline,
    presenceOffline: BPColors.presenceOffline,
    presenceRinging: BPColors.presenceRinging,
    presenceInUse: BPColors.presenceInUse,
    presenceOnHold: BPColors.presenceOnHold,
    theirBubble: BPColors.theirBubbleLight,
    theirBubbleText: Color(0xFF000000),
    ourBubble: BPColors.ourBubbleLight,
    ourBubbleText: Color(0xFF000000),
    streamBackground: BPColors.streamBgLight,
    buddySelected: BPColors.buddySelectedLight,
    buddyActive: BPColors.buddyActiveLight,
    buddyHold: BPColors.buddyHoldLight,
  );

  static const BrowserPhoneColors dark = BrowserPhoneColors(
    answer: BPColors.answer,
    hangup: BPColors.hangup,
    dial: BPColors.dialDark,
    activeCall: BPColors.activeCall,
    holdingCall: BPColors.holdingCall,
    lineIcon: BPColors.lineIcon,
    presenceOnline: BPColors.presenceOnline,
    presenceOffline: BPColors.presenceOffline,
    presenceRinging: BPColors.presenceRinging,
    presenceInUse: BPColors.presenceInUse,
    presenceOnHold: BPColors.presenceOnHold,
    theirBubble: BPColors.theirBubbleDark,
    theirBubbleText: Color(0xFFE1E1E1),
    ourBubble: BPColors.ourBubbleDark,
    ourBubbleText: Color(0xFFE3E3E3),
    streamBackground: BPColors.streamBgDark,
    buddySelected: BPColors.buddySelectedDark,
    buddyActive: BPColors.buddyActiveDark,
    buddyHold: BPColors.buddyHoldDark,
  );

  @override
  BrowserPhoneColors copyWith({
    Color? answer,
    Color? hangup,
    Color? dial,
    Color? activeCall,
    Color? holdingCall,
    Color? lineIcon,
    Color? presenceOnline,
    Color? presenceOffline,
    Color? presenceRinging,
    Color? presenceInUse,
    Color? presenceOnHold,
    Color? theirBubble,
    Color? theirBubbleText,
    Color? ourBubble,
    Color? ourBubbleText,
    Color? streamBackground,
    Color? buddySelected,
    Color? buddyActive,
    Color? buddyHold,
  }) => BrowserPhoneColors(
    answer: answer ?? this.answer,
    hangup: hangup ?? this.hangup,
    dial: dial ?? this.dial,
    activeCall: activeCall ?? this.activeCall,
    holdingCall: holdingCall ?? this.holdingCall,
    lineIcon: lineIcon ?? this.lineIcon,
    presenceOnline: presenceOnline ?? this.presenceOnline,
    presenceOffline: presenceOffline ?? this.presenceOffline,
    presenceRinging: presenceRinging ?? this.presenceRinging,
    presenceInUse: presenceInUse ?? this.presenceInUse,
    presenceOnHold: presenceOnHold ?? this.presenceOnHold,
    theirBubble: theirBubble ?? this.theirBubble,
    theirBubbleText: theirBubbleText ?? this.theirBubbleText,
    ourBubble: ourBubble ?? this.ourBubble,
    ourBubbleText: ourBubbleText ?? this.ourBubbleText,
    streamBackground: streamBackground ?? this.streamBackground,
    buddySelected: buddySelected ?? this.buddySelected,
    buddyActive: buddyActive ?? this.buddyActive,
    buddyHold: buddyHold ?? this.buddyHold,
  );

  @override
  BrowserPhoneColors lerp(
    covariant ThemeExtension<BrowserPhoneColors>? other,
    double t,
  ) {
    if (other is! BrowserPhoneColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    return BrowserPhoneColors(
      answer: l(answer, other.answer),
      hangup: l(hangup, other.hangup),
      dial: l(dial, other.dial),
      activeCall: l(activeCall, other.activeCall),
      holdingCall: l(holdingCall, other.holdingCall),
      lineIcon: l(lineIcon, other.lineIcon),
      presenceOnline: l(presenceOnline, other.presenceOnline),
      presenceOffline: l(presenceOffline, other.presenceOffline),
      presenceRinging: l(presenceRinging, other.presenceRinging),
      presenceInUse: l(presenceInUse, other.presenceInUse),
      presenceOnHold: l(presenceOnHold, other.presenceOnHold),
      theirBubble: l(theirBubble, other.theirBubble),
      theirBubbleText: l(theirBubbleText, other.theirBubbleText),
      ourBubble: l(ourBubble, other.ourBubble),
      ourBubbleText: l(ourBubbleText, other.ourBubbleText),
      streamBackground: l(streamBackground, other.streamBackground),
      buddySelected: l(buddySelected, other.buddySelected),
      buddyActive: l(buddyActive, other.buddyActive),
      buddyHold: l(buddyHold, other.buddyHold),
    );
  }
}

extension BrowserPhoneTheme on ThemeData {
  BrowserPhoneColors get bp =>
      extension<BrowserPhoneColors>() ?? BrowserPhoneColors.light;
}
