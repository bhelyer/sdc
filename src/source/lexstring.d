module source.lexstring;

mixin template LexStringImpl(Token,
                             alias StringSuffixes = ["" : "getStringLiteral"]) {
	/**
	 * Character literals.
	 */
	Token lexCharacter(string s : `'`)() {
		uint l = s.length;
		uint begin = index - l;

		char c = frontChar;
		auto dc = DecodedChar(c);

		if (c < 0x80) {
			const beginEscape = index;
			popChar();

			if (c == '\\' && !lexEscapeSequence(dc)) {
				return getError(beginEscape, "Invalid escape sequence.");
			}
		} else {
			import std.utf;
			size_t i = index;
			dc = DecodedChar(content.decode(i));
			index = cast(uint) i;
		}

		c = frontChar;
		if (c != '\'') {
			return getError(begin, "Expected `\'` to end charatcter literal.");
		}

		popChar();

		auto location = base.getWithOffsets(begin, index);
		return Token.getCharacterLiteral(location, dc);
	}

	/**
	 * String literals.
	 */
	import source.name;
	auto lexStrignSuffix(uint begin, Name value) {
		return lexLiteralSuffix!StringSuffixes(begin, value);
	}

	auto getStringLiteral(string s : "")(Location location, Name value) {
		return Token.getStringLiteral(location, value);
	}

	Token buildRawString(uint begin, size_t start, size_t stop) {
		Name value = decodeLiterals
			? context.getName(content[start .. stop])
			: BuiltinName!"";
		return lexStrignSuffix(begin, value);
	}

	Token lexRawString(char Delimiter = '`')(uint begin) {
		size_t start = index;

		auto c = frontChar;
		while (c != Delimiter && c != '\0') {
			popChar();
			c = frontChar;
		}

		if (c == '\0') {
			return getError(begin, "Unexpected end of file.");
		}

		uint end = index;
		popChar();

		return buildRawString(begin, start, end);
	}

	Token lexString(string s : "`")() {
		uint l = s.length;
		return lexRawString!'`'(index - l);
	}

	Token lexString(string s : "'")() {
		uint l = s.length;
		return lexRawString!'\''(index - l);
	}

	Token lexDecodedString(char Delimiter = '"')(uint begin) {
		size_t start = index;
		string decoded;

		auto c = frontChar;
		while (c != Delimiter && c != '\0') {
			if (c != '\\') {
				popChar();
				c = frontChar;
				continue;
			}

			if (!decodeLiterals) {
				popChar();

				c = frontChar;
				if (c == '\0') {
					break;
				}

				popChar();
				c = frontChar;
				continue;
			}

			scope(success) {
				start = index;
			}

			// Workaround for https://issues.dlang.org/show_bug.cgi?id=22271
			if (decoded == "") {
				decoded = content[start .. index];
			} else {
				decoded ~= content[start .. index];
			}

			const beginEscape = index;
			popChar();

			DecodedChar dc;
			if (!lexEscapeSequence(dc)) {
				return getError(beginEscape, "Invalid escape sequence.");
			}

			decoded = dc.appendTo(decoded);
			c = frontChar;
		}

		if (c == '\0') {
			return getError(begin, "Unexpected end of file.");
		}

		uint end = index;
		popChar();

		Name value;
		if (decodeLiterals) {
			// Workaround for https://issues.dlang.org/show_bug.cgi?id=22271
			if (decoded == "") {
				decoded = content[start .. end];
			} else {
				decoded ~= content[start .. end];
			}

			value = context.getName(decoded);
		}

		return lexStrignSuffix(begin, value);
	}

	Token lexString(string s : `"`)() {
		uint l = s.length;
		return lexDecodedString!'"'(index - l);
	}

	/**
	 * Escape sequences.
	 */
	bool decodeNHexCharacters(uint N, T)(ref T result)
			if (N <= 8 && N <= 2 * T.sizeof) {
		if (index + N >= content.length) {
			return false;
		}

		result = 0;

		bool hasError = false;
		foreach (i; 0 .. N) {
			char c = frontChar;
			popChar();

			uint d = c - '0';
			uint h = ((c | 0x20) - 'a') & 0xff;
			uint n = (d < 10) ? d : (h + 10);

			hasError |= n >= 16;
			result |= n << (4 * (N - i - 1));
		}

		return !hasError;
	}

	bool lexUnicodeEscapeSequence(char C)(ref DecodedChar decoded)
			if (C == 'u' || C == 'U') {
		enum S = 4 * (C == 'U') + 4;

		popChar();

		dchar v;
		if (!decodeNHexCharacters!S(v)) {
			return false;
		}

		import std.utf;
		if (!isValidDchar(v)) {
			return false;
		}

		decoded = DecodedChar(v);
		return true;
	}

	bool lexHtmlEntity(ref DecodedChar decoded) {
		static getMap() {
			string[string] ret;

			import source.htmlentities;
			foreach (ent, _; HtmlEntities) {
				ret[ent ~ ";"] = "singleEntity";
			}

			foreach (ent, _; DoubleHtmlEntities) {
				ret[ent ~ ";"] = "doubleEntity";
			}

			return ret;
		}

		static singleEntity(string E)(ref DecodedChar decoded) {
			import source.htmlentities;
			enum C = HtmlEntities[E[0 .. $ - 1]];

			decoded = DecodedChar(C);
			return true;
		}

		static doubleEntity(string E)(ref DecodedChar decoded) {
			import source.htmlentities;
			enum S = DoubleHtmlEntities[E[0 .. $ - 1]];

			// FIXME: How do we return a string from there?
			return false;
		}

		static fallback(string E)(ref DecodedChar decoded) {
			// FIXME: Lex an identifier and generate a good error.
			return false;
		}

		popChar();
		uint begin = index;

		import source.lexbase;
		// pragma(msg, lexerMixin(getMap(), "fallback", ["decoded"]));
		mixin(lexerMixin(getMap(), "fallback", ["decoded"]));
	}

	bool lexEscapeSequence(ref DecodedChar decoded) {
		char c = frontChar;

		switch (c) {
			case '\'', '"', '\\', '?':
				break;

			case '0':
				c = '\0';
				break;

			case 'a':
				c = '\a';
				break;

			case 'b':
				c = '\b';
				break;

			case 'f':
				c = '\f';
				break;

			case 'r':
				c = '\r';
				break;

			case 'n':
				c = '\n';
				break;

			case 't':
				c = '\t';
				break;

			case 'v':
				c = '\v';
				break;

			case 'x':
				popChar();
				if (!decodeNHexCharacters!2(c)) {
					return false;
				}

				decoded = DecodedChar(c);
				return true;

			case 'u':
				return lexUnicodeEscapeSequence!'u'(decoded);

			case 'U':
				return lexUnicodeEscapeSequence!'U'(decoded);

			case '&':
				return lexHtmlEntity(decoded);

			default:
				return false;
		}

		popChar();
		decoded = DecodedChar(c);
		return true;
	}
}

struct DecodedChar {
private:
	uint content;

public:
	import std.utf;
	this(dchar c) in(isValidDchar(c)) {
		content = c;
	}

	this(char c) {
		content = 0x7fffff00 | c;
	}

	@property
	bool isRaw() const {
		return (content | 0x7fffff00) == content;
	}

	@property
	bool isChar() const {
		return isRaw || content < 0x80;
	}

	@property
	char asChar() const in(isChar) {
		return char(content & 0xff);
	}

	@property
	dchar asDchar() const in(!isRaw) {
		return cast(dchar) content;
	}

	@property
	uint asIntegral() const {
		return isRaw ? asChar : content;
	}

	string appendTo(string s) {
		if (isChar) {
			s ~= asChar;
			return s;
		}

		char[4] buf;

		import std.utf;
		auto i = encode(buf, asDchar);
		s ~= buf[0 .. i];

		return s;
	}
}
