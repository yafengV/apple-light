// TextMate may stop midway through a line at its normal 500 ms budget. Cold
// JavaScript regex compilation can consume that budget; never cache those
// incomplete styles. One bounded retry uses the now-compiled expressions.
export function tokenizeSource(value, language, source, themes) {
  const grammar = value.getLanguage(language), original = grammar.tokenizeLine2;
  let interrupted = false;
  grammar.tokenizeLine2 = function (...args) {
    const result = original.apply(this, args);
    interrupted ||= result.stoppedEarly;
    return result;
  };
  try {
    const options = { lang: language, themes, tokenizeMaxLineLength: 1000, tokenizeTimeLimit: 500 };
    let tokens = value.codeToTokensWithThemes(source, options), recovered = false;
    if (interrupted) {
      interrupted = false; recovered = true;
      tokens = value.codeToTokensWithThemes(source, options);
    }
    if (interrupted) throw Error('Syntax tokenization exceeded the per-line budget');
    return { tokens: tokens.flat(), recovered };
  } finally { grammar.tokenizeLine2 = original; }
}
