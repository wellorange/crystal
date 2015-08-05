class Crystal::Call
  def raise_matches_not_found(owner : CStructType, def_name, matches = nil)
    raise_struct_or_union_field_not_found owner, def_name
  end

  def raise_matches_not_found(owner : CUnionType, def_name, matches = nil)
    raise_struct_or_union_field_not_found owner, def_name
  end

  def raise_struct_or_union_field_not_found(owner, def_name)
    if def_name.ends_with?('=')
    def_name = def_name[0 .. -2]
    end

    var = owner.vars[def_name]?
    if var
      args[0].raise "field '#{def_name}' of #{owner.type_desc} #{owner} has type #{var.type}, not #{args[0].type}"
    else
      raise "#{owner.type_desc} #{owner} has no field '#{def_name}'"
    end
  end

  def raise_matches_not_found(owner, def_name, matches = nil)
    # Special case: Foo+:Class#new
    if owner.is_a?(VirtualMetaclassType) && def_name == "new"
      raise_matches_not_found_for_virtual_metaclass_new owner
    end

    defs = owner.lookup_defs(def_name)

    # Another special case: initialize is only looked up one level,
    # so we must find the first one defined.
    new_owner = owner
    while defs.empty? && def_name == "initialize"
      new_owner = new_owner.superclass
      if new_owner
        defs = new_owner.lookup_defs(def_name)
      else
        defs = [] of Def
        break
      end
    end

    # Check if it's the case of an abstract def
    if !matches || (matches.try &.empty?)
      signature = CallSignature.new(def_name, args.map(&.type), block, named_args)
      defs.each do |a_def|
        if a_def.abstract
          context = MatchContext.new(owner, a_def.owner)
          match = MatchesLookup.match_def(signature, DefWithMetadata.new(a_def), context)
          if match
            if a_def.owner == owner
              owner.all_subclasses.each do |subclass|
                submatches = subclass.lookup_matches(signature)
                if submatches.empty?
                  raise "abstract def #{a_def.owner}##{a_def.name} must be implemented by #{subclass}"
                end
              end
              raise "abstract def #{a_def.owner}##{a_def.name} must be implemented by #{owner}"
            else
              raise "abstract def #{a_def.owner}##{a_def.name} must be implemented by #{owner}"
            end
          end
        end
      end
    end

    obj = @obj
    if defs.empty?
      check_macro_wrong_number_of_arguments(def_name)

      owner_trace = obj.try &.find_owner_trace(owner)
      similar_name = owner.lookup_similar_def_name(def_name, self.args.length, block)

      error_msg = String.build do |msg|
        if obj && owner != mod
          msg << "undefined method '#{def_name}' for #{owner}"
        elsif args.length > 0 || has_parenthesis
          msg << "undefined method '#{def_name}'"
        else
          similar_name = parent_visitor.lookup_similar_var_name(def_name) unless similar_name
          if similar_name == def_name
            # This check is for the case `a if a = 1`
            msg << "undefined method '#{def_name}'"
          else
            msg << "undefined local variable or method '#{def_name}'"
          end
        end

        if obj && obj.type != owner
          msg << colorize(" (compile-time type is #{obj.type})").yellow.bold
        end

        if similar_name
          if similar_name == def_name
            # This check is for the case `a if a = 1`
            msg << colorize(" (if you declared '#{def_name}' in a suffix if, declare it in a regular if for this to work)").yellow.bold
          else
            msg << colorize(" (did you mean '#{similar_name}'?)").yellow.bold
          end
        end

        # Check if it's an instance variable that was never assigned a value
        if obj.is_a?(InstanceVar)
          scope = scope as InstanceVarContainer
          ivar = scope.lookup_instance_var(obj.name)
          deps = ivar.dependencies?
          if deps && deps.length == 1 && deps.first.same?(mod.nil_var)
            similar_name = scope.lookup_similar_instance_var_name(ivar.name)
            if similar_name
              msg << colorize(" (#{ivar.name} was never assigned a value, did you mean #{similar_name}?)").yellow.bold
            else
              msg << colorize(" (#{ivar.name} was never assigned a value)").yellow.bold
            end
          end
        end
      end
      raise error_msg, owner_trace
    end

    real_args_length = self.args.sum do |arg|
      arg_type = arg.type
      if arg.is_a?(Splat) && arg_type.is_a?(TupleInstanceType)
        arg_type.tuple_types.length
      else
        1
      end
    end

    defs_matching_args_length = defs.select do |a_def|
      min_length, max_length = a_def.min_max_args_lengths
      min_length <= real_args_length <= max_length
    end

    if defs_matching_args_length.empty?
      all_arguments_lengths = [] of Int32
      min_splat = Int32::MAX
      defs.each do |a_def|
        min_length, max_length = a_def.min_max_args_lengths
        if max_length == Int32::MAX
          min_splat = Math.min(min_length, min_splat)
          all_arguments_lengths.push min_splat
        else
          min_length.upto(max_length) do |length|
            all_arguments_lengths.push length
          end
        end
      end
      all_arguments_lengths.uniq!.sort!

      raise String.build do |str|
        str << "wrong number of arguments for '"
        str << full_name(owner, def_name)
        str << "' ("
        str << real_args_length
        str << " for "
        all_arguments_lengths.join ", ", str
        if min_splat != Int32::MAX
          str << "+"
        end
        str << ")"
      end
    end

    if defs_matching_args_length.length > 0
      if block && defs_matching_args_length.all? { |a_def| !a_def.yields }
        raise "'#{full_name(owner, def_name)}' is not expected to be invoked with a block, but a block was given"
      elsif !block && defs_matching_args_length.all?(&.yields)
        raise "'#{full_name(owner, def_name)}' is expected to be invoked with a block, but no block was given"
      end

      if named_args = @named_args
        defs_matching_args_length.each do |a_def|
          check_named_args_mismatch owner, named_args, a_def
        end
      end
    end

    if args.length == 1 && args.first.type.includes_type?(mod.nil)
      owner_trace = args.first.find_owner_trace(mod.nil)
    end

    arg_names = [] of Array(String)

    message = String.build do |msg|
      msg << "no overload matches '#{full_name(owner, def_name)}'"
      unless args.empty?
        msg << " with types "
        args.each_with_index do |arg, index|
          msg << ", " if index > 0
          arg_type = arg.type

          if arg.is_a?(Splat) && arg_type.is_a?(TupleInstanceType)
            arg_type.tuple_types.each_with_index do |tuple_type, sub_index|
              msg << ", " if sub_index > 0
              msg << tuple_type
            end
          else
            msg << arg_type
          end
        end
      end
      msg << "\n"

      defs.each do |a_def|
        arg_names.try &.push a_def.args.map(&.name)
      end

      msg << "Overloads are:"
      append_matches(owner, defs, msg)

      if matches
        cover = matches.cover
        if cover.is_a?(Cover)
          missing = cover.missing
          uniq_arg_names = arg_names.uniq!
          uniq_arg_names = uniq_arg_names.length == 1 ? uniq_arg_names.first : nil
          unless missing.empty?
            msg << "\nCouldn't find overloads for these types:"
            missing.each_with_index do |missing_types|
              if uniq_arg_names
                msg << "\n - #{full_name(owner, def_name)}(#{missing_types.map_with_index { |missing_type, i| "#{uniq_arg_names[i]} : #{missing_type}" }.join ", "}"
              else
                msg << "\n - #{full_name(owner, def_name)}(#{missing_types.join ", "}"
              end
              msg << ", &block" if block
              msg << ")"
            end
          end
        end
      end
    end

    raise message, owner_trace
  end

  def append_matches(owner, defs, str, matched_def = nil, argument_name = nil)
    defs.each do |a_def|
      str << "\n - "
      append_def_full_name owner, a_def, str
      if defs.length > 1 && a_def.same?(matched_def)
        str << colorize(" (trying this one)").blue
      end
      if a_def.args.any? { |arg| arg.default_value && arg.name == argument_name }
        str << colorize(" (did you mean this one?)").yellow.bold
      end
    end
  end

  def append_def_full_name(owner, a_def, str)
    str << full_name(owner, a_def.name)
    str << '('
    a_def.args.each_with_index do |arg, i|
      str << ", " if i > 0
      str << '*' if a_def.splat_index == i
      str << arg.name
      if arg_default = arg.default_value
        str << " = "
        str << arg.default_value
      end
      if arg_type = arg.type?
        str << " : "
        str << arg_type
      elsif res = arg.restriction
        str << " : "
        if owner.is_a?(GenericClassInstanceType) && res.is_a?(Path) && res.names.length == 1
          if type_var = owner.type_vars[res.names[0]]?
            str << type_var.type
          else
            str << res
          end
        else
          str << res
        end
      end
    end

    str << ", &block" if a_def.yields
    str << ")"
  end

  def raise_matches_not_found_for_virtual_metaclass_new(owner)
    arg_types = args.map &.type

    owner.each_concrete_type do |concrete_type|
      defs = concrete_type.instance_type.lookup_defs_with_modules("initialize")
      defs = defs.select { |a_def| a_def.args.length != args.length }
      unless defs.empty?
        all_arguments_lengths = Set(Int32).new
        defs.each { |a_def| all_arguments_lengths << a_def.args.length }
        raise "wrong number of arguments for '#{concrete_type.instance_type}#initialize' (#{args.length} for #{all_arguments_lengths.join ", "})"
      end
    end
  end

  def check_macro_wrong_number_of_arguments(def_name)
    macros = in_macro_target &.lookup_macros(def_name)
    return unless macros

    all_arguments_lengths = Set(Int32).new
    macros.each do |a_macro|
      named_args.try &.each do |named_arg|
        index = a_macro.args.index { |arg| arg.name == named_arg.name }
        if index
          if index < args.length
            raise "argument '#{named_arg.name}' already specified"
          end
        else
          raise "no argument named '#{named_arg.name}'"
        end
      end

      min_length = a_macro.args.index(&.default_value) || a_macro.args.length
      min_length.upto(a_macro.args.length) do |args_length|
        all_arguments_lengths << args_length
      end
    end

    raise "wrong number of arguments for macro '#{def_name}' (#{args.length} for #{all_arguments_lengths.join ", "})"
  end

  def check_named_args_mismatch(owner, named_args, a_def)
    named_args.each do |named_arg|
      found_index = a_def.args.index { |arg| arg.name == named_arg.name }
      if found_index
        min_length = args.length
        if found_index < min_length
          named_arg.raise "argument '#{named_arg.name}' already specified"
        end
      else
        similar_name = Levenshtein.find(named_arg.name, a_def.args.select(&.default_value).map(&.name))

        msg = String.build do |str|
          str << "no argument named '"
          str << named_arg.name
          str << "'"
          if similar_name
            str << colorize(" (did you mean '#{similar_name}'?)").yellow.bold
          end

          defs = owner.lookup_defs(a_def.name)

          str << "\n"
          str << "Matches are:"
          append_matches owner, defs, str, matched_def: a_def, argument_name: named_arg.name
        end
        named_arg.raise msg
      end
    end
  end

  def check_visibility(match)
    case match.def.visibility
    when :private
      if obj = @obj
        if obj.is_a?(Var) && obj.name == "self" && match.def.name.ends_with?('=')
          # Special case: private setter can be called with self
          return
        end
        raise "private method '#{match.def.name}' called for #{match.def.owner}"
      end
    when :protected
      unless scope.instance_type.implements?(match.def.owner.instance_type)
        raise "protected method '#{match.def.name}' called for #{match.def.owner}"
      end
    end
  end

  def check_recursive_splat_call(a_def, args)
    if a_def.splat_index
      current_splat_type = args.values.last.type
      if previous_splat_type = mod.splat_expansions[a_def]?
        if current_splat_type.has_in_type_vars?(previous_splat_type)
          raise "recursive splat expansion: #{previous_splat_type}, #{current_splat_type}, ..."
        end
      end
      mod.splat_expansions[a_def] = current_splat_type
      yield
      mod.splat_expansions.delete a_def
    else
      yield
    end
  end

  def full_name(owner, def_name = name)
    owner.to_s_with_method_name(def_name)
  end

  private def colorize(obj)
    mod.colorize(obj)
  end
end
