create or replace package statement_splitter is
--Copyright (C) 2015 Jon Heller.  This program is licensed under the LGPLv3.

function split_by_sqlplus_delimiter(p_statements in clob, p_sqlplus_delimiter in varchar2 default '/') return clob_table;

--DO NOT USE THE BELOW FUNCTION YET, IT HAS SOME SERIOUS PROBLEMS.
function split_by_semicolon(p_tokens in token_table) return token_table_table;

--DO NOT USE THE BELOW FUNCTION YET, IT HAS SOME SERIOUS PROBLEMS.
function split_by_sqlplus_del_and_semi(p_statements in clob, p_sqlplus_delimiter in varchar2 default '/') return token_table_table;

/*

== Purpose ==

Split a string of separate SQL and PL/SQL statements terminated by ";".

Unlike SQL*Plus, even PL/SQL-like statements can be terminiated solely with a ";".
This is helpful because it's difficult to use a "/" in strings in most IDEs.

If you want to run in a more SQL*Plus-like mode, set p_optional_sqlplus_delimiter
to "/".  Then a "/" on a line by itself is also a terminator.  This optional
delimiter is configurable, does not override the ";" terminator, and is removed
from the split strings.


== Output ==

TODO

== Requirements ==

TODO

== Example ==

TODO

*/

end;
/
create or replace package body statement_splitter is

C_TERMINATOR_SEMI              constant number := 1;
C_TERMINATOR_PLSQL_DECLARATION constant number := 2;
C_TERMINATOR_PLSQL             constant number := 3;
C_TERMINATOR_EOF               constant number := 4;





--------------------------------------------------------------------------------
procedure add_statement_consume_tokens(
	p_split_tokens in out nocopy token_table_table,
	p_parse_tree in token_table,
	p_terminator number,
	p_parse_tree_index in out number,
	p_command_name in varchar2
) is
	/*
	This is a recursive descent parser for PL/SQL.
	This link has a good introduction to recursive descent parsers: https://www.cis.upenn.edu/~matuszek/General/recursive-descent-parsing.html)

	The functions roughly follow the same order as the "Block" chapater in the 12c PL/SQL Langauge Reference:
	http://docs.oracle.com/database/121/LNPLS/block.htm#LNPLS01303

	The splitter only needs to know when the statement ends and does not consume
	every token in a meaningful way, like a real parser would.  For example,
	there are many times when tokens can be skipped until the next semicolon.

	If Oracle ever allows PLSQL_DECLARATIONS inside PL/SQL code this code will need to
	be much more complicated.
	*/

	-------------------------------------------------------------------------------
	--Globals
	-------------------------------------------------------------------------------
	--v_code clob := 'declare procedure p1 is begin null; end; begin null; end;select * from dual;';
	--v_code clob := '<<asdf>>declare a number; procedure p1 is begin null; end; begin null; end;select * from dual;';

	--Cursors can have lots of parentheses, and even an "IS" inside them.
	--v_code clob := 'declare cursor c(a number default case when (((1 is null))) then 1 else 0 end) is select 1 a from dual; begin null; end;select * from dual;';
	--v_code clob := '<<asdf>>begin null; end;';

	--SELECT test.
	--v_code clob := 'declare a number; select 1 into a from dual; end;';


	type string_table is table of varchar2(32767);
	type number_table is table of number;
	v_debug_lines string_table := string_table();

	v_abstract_syntax_tree token_table := token_table();
	v_map_between_parse_and_ast number_table := number_table();

	v_ast_index number := 1;
	v_ast_index_at_start number;


	-------------------------------------------------------------------------------
	--Forward declarations so that functions can be in the same order as the documentation.
	-------------------------------------------------------------------------------
	function anything_(p_value varchar2) return boolean;
	function anything_before_begin return boolean;
	function anything_in_parentheses return boolean;
	function anything_up_to_and_including_(p_value varchar2) return boolean;
	function basic_loop_statement return boolean;
	function body return boolean;
	function case_statement return boolean;
	function create_procedure return boolean;
	function create_function return boolean;
	function create_package return boolean;
	function create_type_body return boolean;
	function create_trigger return boolean;
	function cursor_for_loop_statement return boolean;
	function declare_section return boolean;
	function exception_handler return boolean;
	function expression_case_when_then return boolean;
	function for_loop_statement return boolean;
	function function_definition return boolean;
	function if_statement return boolean;
	function label return boolean;
	function name return boolean;
	function p_end return boolean;
	function plsql_block return boolean;
	function procedure_definition return boolean;
	function statement_or_inline_pragma return boolean;


	-------------------------------------------------------------------------------
	--Procedures that wrap functions and ignore output.
	-------------------------------------------------------------------------------
	procedure anything_(p_value varchar2) is v_ignore boolean; begin v_ignore := anything_(p_value); end;
	procedure anything_before_begin is v_ignore boolean; begin v_ignore := anything_before_begin; end;
	procedure anything_in_parentheses is v_ignore boolean; begin v_ignore := anything_in_parentheses; end;
	procedure anything_up_to_and_including_(p_value varchar2) is v_ignore boolean; begin v_ignore := anything_up_to_and_including_(p_value); end;
	procedure body is v_ignore boolean; begin v_ignore := body; end;
	procedure declare_section is v_ignore boolean;begin v_ignore := declare_section; end;
	procedure expression_case_when_then is v_ignore boolean; begin v_ignore := expression_case_when_then; end;
	procedure function_definition is v_ignore boolean; begin v_ignore := function_definition; end;
	procedure label is v_ignore boolean; begin v_ignore := label; end;
	procedure name is v_ignore boolean; begin v_ignore := name; end;
	procedure p_end is v_ignore boolean; begin v_ignore := p_end; end;
	procedure plsql_block is v_ignore boolean; begin v_ignore := plsql_block; end;
	procedure procedure_definition is v_ignore boolean; begin v_ignore := procedure_definition; end;

	-------------------------------------------------------------------------------
	--Helper functions
	-------------------------------------------------------------------------------
	procedure push_line(p_line varchar2) is
	begin
		v_debug_lines.extend;
		v_debug_lines(v_debug_lines.count) := p_line;
	end;

	procedure pop_line is
	begin
		v_debug_lines.trim;
	end;

	procedure increment is begin
		v_ast_index := v_ast_index + 1;
	end;

	function get_next_(p_value varchar2) return number is begin
		for i in v_ast_index .. v_abstract_syntax_tree.count loop
			if upper(v_abstract_syntax_tree(i).value) = p_value then
				return i;
			end if;
		end loop;
		return null;
	end;

	function current_value return clob is begin
		return upper(v_abstract_syntax_tree(v_ast_index).value);
	end;

	function next_value return clob is begin
		begin
			return upper(v_abstract_syntax_tree(v_ast_index+1).value);
		exception when subscript_beyond_count then
			null;
		end;
	end;

	function previous_value(p_decrement number) return clob is begin
		begin
			if v_ast_index - p_decrement <= 0 then
				return null;
			else
				return upper(v_abstract_syntax_tree(v_ast_index - p_decrement).value);
			end if;
		exception when subscript_beyond_count then
			null;
		end;
	end;

	function current_type return varchar2 is begin
		return v_abstract_syntax_tree(v_ast_index).type;
	end;

	function anything_(p_value varchar2) return boolean is begin
		push_line(p_value);
		if current_value = p_value then
			increment;
			return true;
		else
			pop_line;
			return false;
		end if;
	end;

	function anything_up_to_and_including_(p_value varchar2) return boolean is begin
		push_line('ANYTHING_UP_TO_'||p_value);
		loop
			if current_value = p_value then
				increment;
				return true;
			end if;
			increment;
		end loop;
	end;

	function anything_before_begin return boolean is begin
		push_line('ANYTHING_BUT_BEGIN');
		loop
			if current_value = 'BEGIN' then
				return true;
			end if;
			increment;
		end loop;
	end;

	function anything_in_parentheses return boolean is v_paren_counter number; begin
		if current_value = '(' then
			v_paren_counter := 1;
			increment;
			while v_paren_counter >= 1 loop
				if current_value = '(' then
					v_paren_counter := v_paren_counter + 1;
				elsif current_value = ')' then
					v_paren_counter := v_paren_counter - 1;
				end if;
				increment;
			end loop;
			push_line('ANYTHING_IN_PARENTHESES');
			return true;
		end if;
		return false;
	end;

	-------------------------------------------------------------------------------
	--Production rules that consume tokens and return true or false if rule was found.
	-------------------------------------------------------------------------------
	function plsql_block return boolean is begin
		push_line('PLSQL_BLOCK');
		v_ast_index_at_start := v_ast_index;

		label;
		if anything_('DECLARE') then
			declare_section;
			if body then
				return true;
			else
				v_ast_index := v_ast_index_at_start;
				pop_line;
				return false;
			end if;
		elsif body then
			return true;
		else
			v_ast_index := v_ast_index_at_start;
			pop_line;
			return false;
		end if;
	end;

	function label return boolean is begin
		push_line('LABEL');
		if current_value = '<<' then
			loop
				increment;
				if current_value = '>>' then
					increment;
					return true;
				end if;
			end loop;
		end if;
		pop_line;
		return false;
	end;

	function declare_section return boolean is begin
		push_line('DECLARE_SECTION');
		if current_value in ('BEGIN', 'END') then
			return false;
		else
			loop
				if current_value in ('BEGIN', 'END') then
					return true;
				end if;

				--Of the items in ITEM_LIST_1 and ITEM_LIST_2, only
				--these two require any special processing.
				if procedure_definition then null;
				elsif function_definition then null;
				elsif anything_up_to_and_including_(';') then null;
				end if;
			end loop;
		end if;
	end;

	function body return boolean is begin
		push_line('BODY');
		if anything_('BEGIN') then
			while statement_or_inline_pragma loop null; end loop;
			if anything_('EXCEPTION') then
				while exception_handler loop null; end loop;
			end if;
			p_end;
			return true;
		else
			pop_line;
			return false;
		end if;
	end;

	function procedure_definition return boolean is begin
		push_line('PROCEDURE_DEFINITION');
		--Exclude CTE queries that create a table expression named "PROCEDURE".
		if current_value = 'PROCEDURE' and next_value not in ('AS', '(') then
			anything_before_begin; --Don't need the header information.
			return body;
		else
			pop_line;
			return false;
		end if;
	end;

	function function_definition return boolean is begin
		push_line('FUNCTION_DEFINITION');
		--Exclude CTE queries that create a table expression named "FUNCTION".
		if current_value = 'FUNCTION' and next_value not in ('AS', '(') then
			anything_before_begin; --Don't need the header information.
			return body;
		else
			pop_line;
			return false;
		end if;
	end;

	function name return boolean is begin
		push_line('NAME');
		if current_type = tokenizer.c_word then
			increment;
			return true;
		else
			pop_line;
			return false;
		end if;
	end;

	function statement_or_inline_pragma return boolean is begin
		push_line('STATEMENT_OR_INLINE_PRAGMA');
		if label then return true;
		--Types that might have more statements:
		elsif basic_loop_statement then return true;
		elsif case_statement then return true;
		elsif for_loop_statement then return true;
		elsif cursor_for_loop_statement then return true;
		elsif if_statement then return true;
		elsif plsql_block then return true;
		--Anything else
		elsif current_value not in ('EXCEPTION', 'END', 'ELSE', 'ELSIF') then
			return anything_up_to_and_including_(';');
		else
			pop_line;
			return false;
		end if;
	end;

	function p_end return boolean is begin
		push_line('P_END');
		if current_value = 'END' then
			increment;
			name;
			if current_type = ';' then
				increment;
			end if;
			return true;
		end if;
		pop_line;
		return false;
	end;

	function exception_handler return boolean is begin
		push_line('EXCEPTION_HANDLER');
		if current_value = 'WHEN' then
			anything_up_to_and_including_('THEN');
			while statement_or_inline_pragma loop null; end loop;
			return true;
		end if;
		pop_line;
		return false;
	end;

	function basic_loop_statement return boolean is begin
		push_line('BASIC_LOOP_STATEMENT');
		if current_value = 'LOOP' then
			increment;
			while statement_or_inline_pragma loop null; end loop;
			if current_value = 'END' then
				increment;
				if current_value = 'LOOP' then
					increment;
					name;
					if current_value = ';' then
						increment;
						return true;
					end if;
				end if;
			end if;
			raise_application_error(-20330, 'Fatal parse error in BASIC_LOOP_STATEMENT.');
		end if;
		pop_line;
		return false;
	end;

	function for_loop_statement return boolean is begin
		push_line('FOR_LOOP_STATEMENT');
		if current_value = 'FOR' and get_next_('..') < get_next_(';') then
			anything_up_to_and_including_('LOOP');
			while statement_or_inline_pragma loop null; end loop;
			if current_value = 'END' then
				increment;
				if current_value = 'LOOP' then
					increment;
					name;
					if current_value = ';' then
						increment;
						return true;
					end if;
				end if;
			end if;
			raise_application_error(-20330, 'Fatal parse error in FOR_LOOP_STATEMENT.');
		else
			pop_line;
			return false;
		end if;
	end;

	function cursor_for_loop_statement return boolean is begin
		push_line('CURSOR_FOR_LOOP_STATEMENT');
		v_ast_index_at_start := v_ast_index;
		if current_value = 'FOR' then
			increment;
			if name then
				if current_value = 'IN' then
					increment;
					name;
					if current_value = '(' then
						anything_in_parentheses;
						if current_value = 'LOOP' then
							increment;
							while statement_or_inline_pragma loop null; end loop;
							if current_value = 'END' then
								increment;
								if current_value = 'LOOP' then
									increment;
									name;
									if current_value = ';' then
										increment;
										return true;
									end if;
								end if;
							end if;
						end if;
					end if;
				end if;
			end if;
			raise_application_error(-20330, 'Fatal parse error in CURSOR_FOR_LOOP_STATEMENT.');
		else
			v_ast_index := v_ast_index_at_start;
			pop_line;
			return false;
		end if;
	end;

	procedure case_expression is begin
		push_line('CASE_EXPRESSION');
		loop
			if anything_('CASE') then
				case_expression;
				return;
			elsif anything_('END') then
				return;
			else
				increment;
			end if;
		end loop;
		pop_line;
	end;

	function expression_case_when_then return boolean is begin
		push_line('EXPRESSION_CASE_WHEN_THEN');
		loop
			if current_value = 'CASE' then
				case_expression;
			elsif current_value = 'WHEN' or current_value = 'THEN' then
				return true;
			else
				increment;
			end if;
		end loop;
		pop_line;
		return false;
	end;

	function case_statement return boolean is begin
		push_line('CASE_STATEMENT');
		if anything_('CASE') then
			--Searched case.
			if current_value = 'WHEN' then
				while anything_('WHEN') and expression_case_when_then and anything_('THEN') loop
					while statement_or_inline_pragma loop null; end loop;
				end loop;
				if anything_('ELSE') then
					while statement_or_inline_pragma loop null; end loop;
				end if;
				if anything_('END') and anything_('CASE') and (name or not name) and anything_(';') then
					return true;
				end if;
				raise_application_error(-20330, 'Fatal parse error in SEARCHED_CASE_STATEMENT.');
			--Simple case.
			else
				if expression_case_when_then then
					while anything_('WHEN') and expression_case_when_then and anything_('THEN') loop
						while statement_or_inline_pragma loop null; end loop;
					end loop;
					if anything_('ELSE') then
						while statement_or_inline_pragma loop null; end loop;
					end if;
					if anything_('END') and anything_('CASE') and (name or not name) and anything_(';') then
						return true;
					end if;
				end if;
				raise_application_error(-20330, 'Fatal parse error in SIMPLE_CASE_STATEMENT.');
			end if;
		else
			pop_line;
			return false;
		end if;
	end;

	function if_statement return boolean is begin
		push_line('IF_STATEMENT');
		if anything_('IF') then
			if expression_case_when_then and anything_('THEN') then
				while statement_or_inline_pragma loop null; end loop;
				while anything_('ELSIF') and expression_case_when_then and anything_('THEN') loop
					while statement_or_inline_pragma loop null; end loop;
				end loop;
				if anything_('ELSE') then
					while statement_or_inline_pragma loop null; end loop;
				end if;
				if anything_('END') and anything_('IF') and anything_(';') then
					return true;
				end if;
			end if;
			raise_application_error(-20330, 'Fatal parse error in IF_STATEMENT.');
		end if;
		pop_line;
		return false;
	end;

	function create_or_replace_edition return boolean is begin
		push_line('CREATE_OR_REPLACE_EDITION');
		v_ast_index := v_ast_index_at_start;
		if anything_('CREATE') then
			anything_('OR');
			anything_('REPLACE');
			anything_('EDITIONABLE');
			anything_('NONEDITIONABLE');
			return true;
		end if;
		pop_line;
		return false;
	end;

	function create_procedure return boolean is begin
		push_line('CREATE_PROCEDURE');
		v_ast_index_at_start := v_ast_index;
		if create_or_replace_edition and anything_('PROCEDURE') and name then
			if anything_('.') then
				name;
			end if;
			anything_in_parentheses;
			--TODO: Add support for external and call syntax.
			if anything_up_to_and_including_('IS') or anything_up_to_and_including_('AS') then
				plsql_block;
				return true;
			end if;
		end if;
		v_ast_index := v_ast_index_at_start;
		pop_line;
		return false;
	end;

	function create_function return boolean is begin
		push_line('CREATE_FUNCTION');
		v_ast_index_at_start := v_ast_index;
		if create_or_replace_edition and anything_('FUNCTION') and name then
			if anything_('.') then
				name;
			end if;
			anything_in_parentheses;
			--TODO: Add function extra processing - functions may allow an "IS".
			--TODO: Add support for external and call syntax.
			if anything_up_to_and_including_('IS') or anything_up_to_and_including_('AS') then
				plsql_block;
				return true;
			end if;
		end if;
		v_ast_index := v_ast_index_at_start;
		pop_line;
		return false;
	end;

	function create_package_body return boolean is begin
		push_line('CREATE_PACKAGE_BODY');
		v_ast_index_at_start := v_ast_index;
		if create_or_replace_edition and anything_('PACKAGE') and name then
			if anything_('.') then
				name;
			end if;
			anything_in_parentheses;
			if anything_up_to_and_including_('IS') or anything_up_to_and_including_('AS') then
				loop
					if anything_('END') then
						name;
						anything_(';');
						return true;
					else
						anything_up_to_and_including_(';');
					end if;
				end loop;
			end if;
		end if;
		v_ast_index := v_ast_index_at_start;
		pop_line;
		return false;
	end;

	function create_package return boolean is begin
		push_line('CREATE_PACKAGE');
		v_ast_index_at_start := v_ast_index;
		if create_or_replace_edition and anything_('PACKAGE') and anything_('BODY') and name then
			if anything_('.') then
				name;
			end if;
			if anything_('IS') or anything_('AS') then
				declare_section;
				body;
				if anything_('END') then
					name;
					anything_(';');
					return true;
				end if;
			end if;
		end if;
		v_ast_index := v_ast_index_at_start;
		pop_line;
		return false;
	end;

	function create_type_body return boolean is begin
		push_line('CREATE_TYPE_BODY');
		v_ast_index_at_start := v_ast_index;
		if create_or_replace_edition and anything_('TYPE') and anything_('BODY') and name then
			if anything_('.') then
				name;
			end if;
			anything_in_parentheses;
			if anything_up_to_and_including_('IS') or anything_up_to_and_including_('AS') then
				loop
					if anything_('END') and anything_(';') then
						return true;
					elsif current_value in ('MAP', 'ORDER', 'MEMBER') then
						anything_('MAP');
						anything_('ORDER');
						anything_('MEMBER');
						if procedure_definition or function_definition then
							null;
						end if;
					elsif current_value in ('FINAL', 'INSTANTIABLE', 'CONSTRUCTOR') then
						anything_('FINAL');
						anything_('INSTANTIABLE');
						anything_('CONSTRUCTOR');
						function_definition;
					else
						anything_up_to_and_including_(';');
					end if;
				end loop;
			end if;
			raise_application_error(-20330, 'Fatal parse error in CREATE_TYPE_BODY.');
		end if;
		v_ast_index := v_ast_index_at_start;
		pop_line;
		return false;
	end;

	function create_trigger return boolean is begin
		push_line('');
		--TODO;
/*
			if v_trigger_type = statement_classifier.C_TRIGGER_TYPE_REGULAR then
				add_statement_consume_tokens(v_split_tokens, p_tokens, C_TERMINATOR_PLSQL_MATCHED_END, v_parse_tree_index, v_command_name, v_trigger_body_start_index);
			elsif v_trigger_type = statement_classifier.C_TRIGGER_TYPE_COMPOUND then
				add_statement_consume_tokens(v_split_tokens, p_tokens, C_TERMINATOR_PLSQL_EXTRA_END, v_parse_tree_index, v_command_name, v_trigger_body_start_index);
			elsif v_trigger_type = statement_classifier.C_TRIGGER_TYPE_CALL then
				add_statement_consume_tokens(v_split_tokens, p_tokens, C_TERMINATOR_SEMI, v_parse_tree_index, v_command_name, v_trigger_body_start_index);
			end if;
*/
		pop_line;
		return false;
	end;


begin
	--Convert parse tree into abstract syntax tree by removing whitespace, comment, and EOF.
	--Also create a map between the two.
	for i in p_parse_tree_index .. p_parse_tree.count loop
		if p_parse_tree(i).type not in (tokenizer.c_whitespace, tokenizer.c_comment, tokenizer.c_eof) then
			v_abstract_syntax_tree.extend;
			v_abstract_syntax_tree(v_abstract_syntax_tree.count) := p_parse_tree(i);

			v_map_between_parse_and_ast.extend;
			v_map_between_parse_and_ast(v_map_between_parse_and_ast.count) := i;
		end if;
	end loop;

	--Find the last AST token index.
	--
	--Consume everything
	if p_terminator = C_TERMINATOR_EOF then
		v_ast_index := v_abstract_syntax_tree.count + 1;

	--Look for a ';' anywhere.
	elsif p_terminator = C_TERMINATOR_SEMI then
		--Loop through all tokens, exit if a semicolon found.
		for i in 1 .. v_abstract_syntax_tree.count loop
			if v_abstract_syntax_tree(i).type = ';' then
				v_ast_index := i + 1;
				exit;
			end if;
			v_ast_index := i + 1;
		end loop;

	--Match BEGIN and END for a PLSQL_DECLARATION.
	elsif p_terminator = C_TERMINATOR_PLSQL_DECLARATION then
		/*
		PL/SQL Declarations must have this pattern before the first ";":
			(null or not "START") "WITH" ("FUNCTION"|"PROCEDURE") (neither "(" nor "AS")

		This was discovered by analyzing all "with" strings in the Oracle documentation
		text descriptions.  That is, download the library and run a command like this:
			C:\E50529_01\SQLRF\img_text> findstr /s /i "with" *.*

		SQL has mnay ambiguities, simply looking for "with function" would incorrectly catch these:
			1. Hierarchical queries.  Exclude them by looking for "start" before "with".
				select * from (select 1 function from dual)	connect by function = 1	start with function = 1;
			2. Subquery factoring that uses "function" as a name.  Stupid, but possible.
				with function as (select 1 a from dual) select * from function;
				with function(a) as (select 1 a from dual) select * from function;
			Note: "start" cannot be the name of a table, no need to worry about DML
			statements like `insert into start with ...`.
		*/
		for i in 1 .. v_abstract_syntax_tree.count loop
			if
			(
				(previous_value(2) is null or previous_value(2) <> 'START')
				and previous_value(1) = 'WITH'
				and current_value in ('FUNCTION', 'PROCEDURE')
				and (next_value is null or next_value not in ('(', 'AS'))
			) then
				if current_value in ('FUNCTION', 'PROCEDURE') then
					while function_definition or procedure_definition loop null; end loop;
				end if;
			elsif v_abstract_syntax_tree(v_ast_index).type = ';' then
				v_ast_index := v_ast_index + 1;
				exit;
			else
				v_ast_index := v_ast_index + 1;
			end if;
		end loop;
	--Match BEGIN and END for a common PL/SQL block.
	elsif p_terminator = C_TERMINATOR_PLSQL then
		if plsql_block then null;
		elsif create_procedure then null;
		elsif create_function then null;
		elsif create_package_body then null;
		elsif create_package then null;
		elsif create_type_body then null;
		elsif create_trigger then null;
		else
			raise_application_error(-20330, 'Fatal parse error in '||p_command_name);
		end if;
	end if;

/*
	--DEBUG TODO
	for i in 1 .. v_debug_lines.count loop
		dbms_output.put_line(v_debug_lines(i));
	end loop;
*/

	--Create a new parse tree with the new tokens.
	<<create_parse_tree>>
	declare
		v_new_parse_tree token_table := token_table();
		v_has_abstract_token boolean := false;
	begin
		--Special case if there are no abstract syntax tokens - add everything.
		if v_ast_index = 1 then
			--Create new parse tree.
			for i in p_parse_tree_index .. p_parse_tree.count loop
				v_new_parse_tree.extend;
				v_new_parse_tree(v_new_parse_tree.count) := p_parse_tree(i);
			end loop;

			--Add new parse tree.
			p_split_tokens.extend;
			p_split_tokens(p_split_tokens.count) := v_new_parse_tree;

			--Set the parse tree index to the end, plus one to stop loop.
			p_parse_tree_index := p_parse_tree.count + 1;

		--Else iterate up to the last abstract syntax token and maybe some extra whitespace.
		else
			--Iterate selected parse tree tokens, add them to collection.
			for i in p_parse_tree_index .. v_map_between_parse_and_ast(v_ast_index-1) loop
				v_new_parse_tree.extend;
				v_new_parse_tree(v_new_parse_tree.count) := p_parse_tree(i);
			end loop;

			--Are any of the remaining tokens abstract?
			for i in v_map_between_parse_and_ast(v_ast_index-1) + 1 .. p_parse_tree.count loop
				if p_parse_tree(i).type not in (tokenizer.c_whitespace, tokenizer.c_comment, tokenizer.c_eof) then
					v_has_abstract_token := true;
					exit;
				end if;
			end loop;

			--If no remaining tokens are abstract, add them to the new parse tree.
			--Whitespace and comments after the last statement belong to that statement, not a new one.
			if not v_has_abstract_token then
				for i in v_map_between_parse_and_ast(v_ast_index-1) + 1 .. p_parse_tree.count loop
					v_new_parse_tree.extend;
					v_new_parse_tree(v_new_parse_tree.count) := p_parse_tree(i);
				end loop;

				--Set the parse tree index to the end, plus one to stop loop.
				p_parse_tree_index := p_parse_tree.count + 1;
			else
				--Set the parse tree index based on the last AST index.
				p_parse_tree_index := v_map_between_parse_and_ast(v_ast_index-1) + 1;
			end if;

			--Add new tree to collection of trees.
			p_split_tokens.extend;
			p_split_tokens(p_split_tokens.count) := v_new_parse_tree;
		end if;
	end;

end add_statement_consume_tokens;


--------------------------------------------------------------------------------
--Split a token stream into statements by ";".
function split_by_semicolon(p_tokens in token_table)
return token_table_table is
	v_split_tokens token_table_table := token_table_table();
	v_command_name varchar2(4000);
	v_parse_tree_index number := 1;
begin
	--Split into statements.
	loop
		--Classify.
		declare
			v_throwaway_number number;
			v_throwaway_string varchar2(32767);
		begin
			statement_classifier.classify(
				p_tokens => p_tokens,
				p_category => v_throwaway_string,
				p_statement_type => v_throwaway_string,
				p_command_name => v_command_name,
				p_command_type => v_throwaway_number,
				p_lex_sqlcode => v_throwaway_number,
				p_lex_sqlerrm => v_throwaway_string,
				p_start_index => v_parse_tree_index
			);
		end;

		--Find a terminating token based on the classification.
		--
		--TODO: CREATE OUTLINE, CREATE SCHEMA, and some others may also differ depending on presence of PLSQL_DECLARATION.
		--
		--#1: Return everything with no splitting if the statement is Invalid or Nothing.
		--    These are probably errors but the application must decide how to handle them.
		if v_command_name in ('Invalid', 'Nothing') then
			add_statement_consume_tokens(v_split_tokens, p_tokens, C_TERMINATOR_EOF, v_parse_tree_index, v_command_name);

		--#2: Match "}" for Java code.
		/*
			'CREATE JAVA', if "{" is found before first ";"
			Note: Single-line comments are different, "//".  Exclude any "", "", or "" after a
				Create java_partial_tokenizer to lex Java statements (Based on: https://docs.oracle.com/javase/specs/jls/se7/html/jls-3.html), just need:
					- multi-line comment
					- single-line comment - Note Lines are terminated by the ASCII characters CR, or LF, or CR LF.
					- character literal - don't count \'
					- string literal - don't count \"
					- {
					- }
					- other
					- Must all files end with }?  What about packages only, or annotation only file?

				CREATE JAVA CLASS USING BFILE (java_dir, 'Agent.class')
				CREATE JAVA SOURCE NAMED "Welcome" AS public class Welcome { public static String welcome() { return "Welcome World";   } }
				CREATE JAVA RESOURCE NAMED "appText" USING BFILE (java_dir, 'textBundle.dat')

				TODO: More examples using lexical structures.
		*/
		elsif v_command_name in ('CREATE JAVA') then
			--TODO
			raise_application_error(-20000, 'CREATE JAVA is not yet supported.');

		--#3: Match PLSQL_DECLARATION BEGIN and END.
		elsif v_command_name in
		(
			'CREATE MATERIALIZED VIEW ', 'CREATE SCHEMA', 'CREATE TABLE', 'CREATE VIEW',
			'DELETE', 'EXPLAIN', 'INSERT', 'SELECT', 'UPDATE', 'UPSERT'
		) then
			add_statement_consume_tokens(v_split_tokens, p_tokens, C_TERMINATOR_PLSQL_DECLARATION, v_parse_tree_index, v_command_name);

		--#4: Match PL/SQL BEGIN and END.
		elsif v_command_name in
		(
			'PL/SQL EXECUTE', 'CREATE FUNCTION','CREATE PROCEDURE', 'CREATE PACKAGE',
			'CREATE PACKAGE BODY', 'CREATE TYPE BODY', 'CREATE TRIGGER'
		) then
			add_statement_consume_tokens(v_split_tokens, p_tokens, C_TERMINATOR_PLSQL, v_parse_tree_index, v_command_name);

		--#5: Stop at first ";" for everything else.
		else
			add_statement_consume_tokens(v_split_tokens, p_tokens, C_TERMINATOR_SEMI, v_parse_tree_index, v_command_name);
		end if;

		--Quit when there are no more tokens.
		exit when v_parse_tree_index > p_tokens.count;
	end loop;

	--TODO: Fix line_number, column_number, first_char_position and last_char_position.

	return v_split_tokens;
end split_by_semicolon;


--------------------------------------------------------------------------------
--Split a string into separate strings by an optional delmiter, usually "/".
--This follows the SQL*Plus rules - the delimiter must be on a line by itself,
--although the line may contain whitespace before and after the delimiter.
--The delimiter and whitespace on the same line are included with the first statement.
function split_by_sqlplus_delimiter(p_statements in clob, p_sqlplus_delimiter in varchar2 default '/') return clob_table is
	v_chars varchar2_table := tokenizer.get_varchar2_table_from_clob(p_statements);
	v_delimiter_size number := nvl(lengthc(p_sqlplus_delimiter), 0);
	v_char_index number := 0;
	v_string clob;
	v_is_empty_line boolean := true;

	v_strings clob_table := clob_table();

	--Get N chars for comparing with multi-character delimiter.
	function get_next_n_chars(p_n number) return varchar2 is
		v_next_n_chars varchar2(32767);
	begin
		for i in v_char_index .. least(v_char_index + p_n - 1, v_chars.count) loop
			v_next_n_chars := v_next_n_chars || v_chars(i);
		end loop;

		return v_next_n_chars;
	end get_next_n_chars;

	--Check if there are only whitespace characters before the next newline
	function only_ws_before_next_newline return boolean is
	begin
		--Loop through the characters.
		for i in v_char_index + v_delimiter_size .. v_chars.count loop
			--TRUE if a newline is found.
			if v_chars(i) = chr(10) then
				return true;
			--False if non-whitespace is found.
			elsif not tokenizer.is_lexical_whitespace(v_chars(i)) then
				return false;
			end if;
		end loop;

		--True if neither a newline or a non-whitespace was found.
		return true;
	end only_ws_before_next_newline;
begin
	--Special cases.
	--
	--Throw an error if the delimiter is null.
	if p_sqlplus_delimiter is null then
		raise_application_error(-20000, 'The SQL*Plus delimiter cannot be NULL.');
	end if;
	--Throw an error if the delimiter contains whitespace.
	for i in 1 .. lengthc(p_sqlplus_delimiter) loop
		if tokenizer.is_lexical_whitespace(substrc(p_sqlplus_delimiter, i, 1)) then
			raise_application_error(-20001, 'The SQL*Plus delimiter cannot contain whitespace.');
		end if;
	end loop;
	--Return an empty string if the string is NULL.
	if p_statements is null then
		v_strings.extend;
		v_strings(v_strings.count) := p_statements;
		return v_strings;
	end if;

	--Loop through characters and build strings.
	loop
		v_char_index := v_char_index + 1;

		--Look for delimiter if it's on an empty line.
		if v_is_empty_line then
			--Add char, push, and exit if it's the last character.
			if v_char_index = v_chars.count then
				v_string := v_string || v_chars(v_char_index);
				v_strings.extend;
				v_strings(v_strings.count) := v_string;
				exit;
			--Continue if it's still whitespace.
			elsif tokenizer.is_lexical_whitespace(v_chars(v_char_index)) then
				v_string := v_string || v_chars(v_char_index);
			--Split string if delimiter is found.
			elsif get_next_n_chars(v_delimiter_size) = p_sqlplus_delimiter and only_ws_before_next_newline then
				--Consume delimiter.
				for i in 1 .. v_delimiter_size loop
					v_string := v_string || v_chars(v_char_index);
					v_char_index := v_char_index + 1;
				end loop;

				--Consume all tokens until either end of string or next character is non-whitespace.
				loop
					v_string := v_string || v_chars(v_char_index);
					v_char_index := v_char_index + 1;
					exit when v_char_index = v_chars.count or not tokenizer.is_lexical_whitespace(v_chars(v_char_index));
				end loop;

				--Remove extra increment.
				v_char_index := v_char_index - 1;

				--Add string and start over.
				v_strings.extend;
				v_strings(v_strings.count) := v_string;
				v_string := null;
				v_is_empty_line := false;
			--It's no longer an empty line otherwise.
			else
				v_string := v_string || v_chars(v_char_index);
				v_is_empty_line := false;
			end if;
		--Add the string after the last character.
		elsif v_char_index >= v_chars.count then
			v_string := v_string || v_chars(v_char_index);
			v_strings.extend;
			v_strings(v_strings.count) := v_string;
			exit;
		--Look for newlines.
		elsif v_chars(v_char_index) = chr(10) then
			v_string := v_string || v_chars(v_char_index);
			v_is_empty_line := true;
		--Else just add the character.
		else
			v_string := v_string || v_chars(v_char_index);
		end if;
	end loop;

	return v_strings;
end split_by_sqlplus_delimiter;


--------------------------------------------------------------------------------
--Split a string of separate SQL and PL/SQL statements terminated by ";" and
--some secondary terminator, usually "/".
function split_by_sqlplus_del_and_semi(p_statements in clob, p_sqlplus_delimiter in varchar2 default '/')
return token_table_table is
	v_split_statements clob_table := clob_table();
	v_split_token_tables token_table_table := token_table_table();
begin
	--First split by SQL*Plus delimiter.
	v_split_statements := split_by_sqlplus_delimiter(p_statements, p_sqlplus_delimiter);

	--Split each string further by the primary terminator, ";".
	for i in 1 .. v_split_statements.count loop
		v_split_token_tables :=
			v_split_token_tables
			multiset union
			split_by_semicolon(tokenizer.tokenize(v_split_statements(i)));
	end loop;

	--Return the statements.
	return v_split_token_tables;
end split_by_sqlplus_del_and_semi;


end;
/
