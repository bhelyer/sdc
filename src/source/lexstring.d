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
		const start = index;
		auto dc = DecodedChar(c);

		if (c == '\0') {
			return getError(begin, "Unexpected end of file.");
		}

		if (c == '\'') {
			popChar();
			return getError(begin, "Character literals cannot be empty.");
		}

		if (c == '\\') {
			popChar();

			auto es = lexEscapeSequence(start);
			if (es.type == SequenceType.Invalid) {
				if (frontChar == '\'') {
					popChar();
				}

				return getError(es.location, es.error);
			}

			dc = es.decodedChar;
		} else {
			dchar d;

			import source.util.utf8;
			if (!decode(content, index, d)) {
				return getError(start, "Invalid UTF-8 sequence.");
			}

			dc = DecodedChar(d);
		}

		c = frontChar;
		if (c != '\'') {
			import std.format;
			return getError(
				begin,
				format!"Expected `\'` to end charatcter literal, not %(%s%)."(
					(&c)[0 .. 1]),
			);
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

		uint end = popChar();
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

			auto es = lexEscapeSequence(beginEscape);
			if (es.type == SequenceType.Invalid) {
				return getError(es.location, es.error);
			}

			decoded = es.appendTo(decoded);
			c = frontChar;
		}

		if (c == '\0') {
			return getError(begin, "Unexpected end of file.");
		}

		uint end = popChar();

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
	import source.escapesequence;
	auto getEscapeSequenceError(uint begin, string error) {
		return EscapeSequence.fromError(base.getWithOffsets(begin, index),
		                                context.getName(error));
	}

	EscapeSequence lexOctalEscapeSequence(uint begin) {
		uint r = 0;
		foreach (i; 0 .. 3) {
			auto c = frontChar;
			if (c < '0' || c > '7') {
				break;
			}

			popChar();
			r = (r * 8) | (c - '0');
			c = frontChar;
		}

		if (r <= 0xff) {
			return EscapeSequence(char(r & 0xff));
		}

		import std.format;
		return getEscapeSequenceError(
			begin,
			format!"Escape octal sequence \\%03o is larger than \\377."(r),
		);
	}

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

	import source.decodedchar;
	EscapeSequence lexUnicodeEscapeSequence(char C)(uint begin)
			if (C == 'u' || C == 'U') {
		enum S = 4 * (C == 'U') + 4;

		popChar();

		dchar v;
		if (!decodeNHexCharacters!S(v)) {
			goto Error;
		}

		import std.utf;
		if (isValidDchar(v)) {
			return EscapeSequence(v);
		}

	Error:
		import std.format;
		return getEscapeSequenceError(
			begin,
			format!"%s is not a valid unicode character."(
				content[begin .. index]),
		);
	}

	EscapeSequence lexEscapeSequence(uint begin) {
		char c = frontChar;
		switch (c) {
			case '\'', '"', '\\', '?':
				break;

			case '0':
				c = '\0';
				break;

			case '1': .. case '7':
				return lexOctalEscapeSequence(begin);

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
				if (decodeNHexCharacters!2(c)) {
					return EscapeSequence(c);
				}

				import std.format;
				return getEscapeSequenceError(
					begin,
					format!"%s is not a valid hexadecimal sequence."(
						content[begin .. index])
				);

			case 'u':
				return lexUnicodeEscapeSequence!'u'(begin);

			case 'U':
				return lexUnicodeEscapeSequence!'U'(begin);

			case '&':
				assert(0, "HTML5 named character references not implemented");

			default:
				return
					getEscapeSequenceError(begin, "Invalid escape sequence.");
		}

		popChar();
		return EscapeSequence(c);
	}
}

unittest {
	import source.context, source.dlexer;
	auto context = new Context();

	auto makeTestLexer(string s) {
		import source.location, source.name;
		auto base = context.registerMixin(Location.init, s ~ '\0');
		return lex(base, context);
	}

	auto checkLexChar(string s, uint expected) {
		auto lex = makeTestLexer(s);

		import source.parserutil;
		lex.match(TokenType.Begin);

		auto t = lex.match(TokenType.CharacterLiteral);
		assert(t.decodedChar.asIntegral == expected);

		assert(lex.front.type == TokenType.End);
	}

	auto checkLexString(string s, string expected) {
		auto lex = makeTestLexer(s);

		import source.parserutil;
		lex.match(TokenType.Begin);

		auto t = lex.match(TokenType.StringLiteral);
		assert(t.decodedString.toString(context) == expected);

		assert(lex.front.type == TokenType.End);
	}

	auto checkLexInvalid(string s, string error) {
		auto lex = makeTestLexer(s);

		import source.parserutil;
		lex.match(TokenType.Begin);

		auto t = lex.match(TokenType.Invalid);
		assert(t.error.toString(context) == error, t.error.toString(context));
	}

	// Check for plain old ASCII.
	checkLexString(`""`, "");
	checkLexString(`"foobar"`, "foobar");

	checkLexChar("'a'", 0x61);
	checkLexInvalid(`''`, "Character literals cannot be empty.");
	checkLexInvalid(`'aa'`, "Expected `'` to end charatcter literal, not 'a'.");
	checkLexInvalid("'\xc0'", "Invalid UTF-8 sequence.");

	// Invalid strings and characters.
	checkLexInvalid(`"`, "Unexpected end of file.");
	checkLexInvalid(`'`, "Unexpected end of file.");

	// Check unicode support.
	checkLexString(`"\U0001F0BD\u0393α\u1FD6\u03B1\U0001FA01🙈🙉🙊\U0001F71A"`,
	               "🂽Γαῖα🨁🙈🙉🙊🜚");

	checkLexChar(`'\U0001F0BD'`, 0x1F0BD);
	checkLexChar(`'\u0393'`, 0x393);
	checkLexChar(`'α'`, 0x3B1);
	checkLexChar(`'\u1FD6'`, 0x1FD6);
	checkLexChar(`'\u03B1'`, 0x3B1);
	checkLexChar(`'\U0001FA01'`, 0x1FA01);
	checkLexChar(`'🙈'`, 0x1F648);
	checkLexChar(`'🙉'`, 0x1F649);
	checkLexChar(`'🙊'`, 0x1F64a);
	checkLexChar(`'\U0001FA01'`, 0x1FA01);

	checkLexInvalid(`"\U0001F0B"`,
	                `\U0001F0B" is not a valid unicode character.`);
	checkLexInvalid(`"\u039"`, `\u039" is not a valid unicode character.`);
	checkLexInvalid(`"\u039G"`, `\u039G is not a valid unicode character.`);
	checkLexInvalid(`"\u03@3"`, `\u03@3 is not a valid unicode character.`);

	// Check other escaped characters.
	checkLexString(`"\'\"\?\0\a\b\f\r\n\t\v"`, "\'\"\?\0\a\b\f\r\n\t\v");
	checkLexInvalid(`"\c"`, "Invalid escape sequence.");

	checkLexChar(`'\"'`, 0x22);
	checkLexChar(`'\''`, 0x27);
	checkLexChar(`'\?'`, 0x3f);

	checkLexChar(`'\0'`, 0);
	checkLexChar(`'\a'`, 7);
	checkLexChar(`'\b'`, 8);
	checkLexChar(`'\t'`, 9);
	checkLexChar(`'\n'`, 10);
	checkLexChar(`'\v'`, 11);
	checkLexChar(`'\f'`, 12);
	checkLexChar(`'\r'`, 13);
	checkLexInvalid(`'\c'`, "Invalid escape sequence.");

	// Check hexadecimal escape sequences.
	checkLexString(`"\xfa\xff\x20\x00\xAA\xf0\xa0"`,
	               "\xfa\xff\x20\x00\xAA\xf0\xa0");
	checkLexInvalid(`"\xgg"`, `\xgg is not a valid hexadecimal sequence.`);

	checkLexChar(`'\xfa'`, 0xfa);
	checkLexChar(`'\xff'`, 0xff);
	checkLexChar(`'\x20'`, 0x20);
	checkLexChar(`'\x00'`, 0x00);
	checkLexChar(`'\xAA'`, 0xAA);
	checkLexChar(`'\xf0'`, 0xf0);
	checkLexChar(`'\xa0'`, 0xa0);
	checkLexInvalid(`'\xgg'`, `\xgg is not a valid hexadecimal sequence.`);

	// Check octal escape sequences.
	checkLexString(`"\0\1\11\44\77\111\377"`, "\0\x01\x09\x24\x3f\x49\xff");
	checkLexString(`"\1111\378"`, "\x491\x1f8");
	checkLexInvalid(`"\400"`,
	                `Escape octal sequence \400 is larger than \377.`);

	checkLexChar(`'\0'`, 0);
	checkLexChar(`'\1'`, 0x01);
	checkLexChar(`'\11'`, 0x09);
	checkLexChar(`'\44'`, 0x24);
	checkLexChar(`'\77'`, 0x3f);
	checkLexChar(`'\111'`, 0x49);
	checkLexChar(`'\377'`, 0xff);
	checkLexInvalid(`'\1111'`,
	                "Expected `'` to end charatcter literal, not '1'.");
	checkLexInvalid(`'\378'`,
	                "Expected `'` to end charatcter literal, not '8'.");
	checkLexInvalid(`'\400'`,
	                `Escape octal sequence \400 is larger than \377.`);
}
