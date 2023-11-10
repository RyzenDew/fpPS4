unit kern_reloc;

{$mode ObjFPC}{$H+}
{$CALLING SysV_ABI_CDecl}

interface

uses
 sysutils,
 elf64,
 kern_rtld,
 subr_dynlib;

function reloc_non_plt(obj:p_lib_info;flags:DWORD):Integer;
function reloc_jmpslots(obj:p_lib_info;flags:DWORD):Integer;
function relocate_one_object(obj:p_lib_info;jmpslots,export_only:Boolean):Integer;
function check_copy_relocations(obj:p_lib_info):Integer;
function dynlib_unlink_imported_symbols_each(root,obj:p_lib_info):Integer;

implementation

uses
 errno,
 systm,
 kern_dlsym;

function check_addr(obj:p_lib_info;where:Pointer;size:Integer):Integer;
var
 map_base:Pointer;
 relro_addr:Pointer;
begin
 map_base:=obj^.map_base;
 relro_addr:=obj^.relro_addr;

 if ( (map_base > where) or
      ((map_base + obj^.text_size) < (where + size))
    ) and

    ( (obj^.data_addr > where) or
      ((obj^.data_addr + obj^.data_size) < (where + size))

    ) and
    ( (relro_addr=nil) or
      (relro_addr > where) or
      (obj^.relro_size=0) or
      ((relro_addr + obj^.relro_size) < (where + size))
    ) then
 begin
  //dont check with special callbacks
  Exit(ENOEXEC);
 end;

 Result:=0;
end;

function reloc_non_plt(obj:p_lib_info;flags:DWORD):Integer;
label
 _next,
 _move64;
var
 rela:p_elf64_rela;
 sym_zero:p_elf64_sym;

 where:Pointer;
 data:Pointer;

 data32:Integer;
 r_type:Integer;

 def:p_elf64_sym;
 defobj:p_lib_info;

 cache:array of t_SymCache;

 i,count:Integer;
begin
 Result:=0;

 cache:=nil;
 SetLength(cache,obj^.rel_data^.dynsymcount);

 sym_zero:=@dynlibs_info.sym_zero;

 rela :=obj^.rel_data^.rela_addr;
 count:=obj^.rel_data^.rela_size div SizeOf(elf64_rela);

 defobj:=nil;

 if (rela<>nil) and (count<>0) then
 For i:=0 to count-1 do
 begin
  if not check_relo_bits(obj,i) then
  begin
   where:=Pointer(obj^.relocbase)+rela^.r_offset;

   r_type:=ELF64_R_TYPE(rela^.r_info);

   case r_type of

    R_X86_64_NONE:; //ignore

    R_X86_64_COPY:
      if (obj^.rtld_flags.mainprog=0) then
      begin
       Writeln(StdErr,'reloc_non_plt:','Unexpected R_X86_64_COPY relocation in shared library ',dynlib_basename(obj^.lib_path));
       Exit(ENOEXEC);
      end; //R_X86_64_COPY

    R_X86_64_RELATIVE:
      begin
       Result:=check_addr(obj,where,SizeOf(Pointer));
       if (Result<>0) then
       begin
        Writeln(StdErr,'reloc_non_plt:','idx=',i,' where=0x',HexStr(where),' ref=',dynlib_basename(obj^.lib_path));
        Exit;
       end;

       data:=(obj^.relocbase + rela^.r_addend);

       defobj:=obj;
       goto _move64;
      end; //R_X86_64_RELATIVE

    R_X86_64_64,
    R_X86_64_GLOB_DAT,
    R_X86_64_DTPMOD64,
    R_X86_64_DTPOFF64,
    R_X86_64_TPOFF64: //64
      begin
       Result:=check_addr(obj,where,SizeOf(Pointer));
       if (Result<>0) then
       begin
        Writeln(StdErr,'reloc_non_plt:','idx=',i,' where=0x',HexStr(where),' ref=',dynlib_basename(obj^.lib_path));
        Exit;
       end;

       def:=find_symdef(ELF64_R_SYM(rela^.r_info),obj,defobj,flags,@cache[0],where);

       if (def<>nil) then
        case r_type of
         R_X86_64_64:
           begin
            data:=(defobj^.relocbase + rela^.r_addend + def^.st_value);

            if (def<>sym_zero) then
            begin
             goto _move64;
            end;
           end; //R_X86_64_64

         R_X86_64_GLOB_DAT:
           begin
            data:=(defobj^.relocbase + def^.st_value);

            if (def<>sym_zero) then
            begin
             goto _move64;
            end;
           end; //R_X86_64_GLOB_DAT

         R_X86_64_DTPMOD64:
           begin
            Result:=copyin(where,@data,SizeOf(Pointer)); //data:=where^
            if (Result<>0) then
            begin
             Writeln(StdErr,'reloc_non_plt:','copyin() failed. where=0x',HexStr(where),' [',r_type,']');
             Exit(ENOEXEC);
            end;

            data:=(data + defobj^.tls_index);

            Result:=copyout(@data,where,8); //where^:=data
            if (Result<>0) then
            begin
             Writeln(StdErr,'reloc_non_plt:','copyout() failed. where=0x',HexStr(where),' [',r_type,']');
             Exit(ENOEXEC);
            end;

            if (def<>@dynlibs_info.sym_nops) then
            begin
             set_relo_bits(obj,i);
            end;
           end; //R_X86_64_DTPMOD64

         R_X86_64_DTPOFF64:
           begin
            Result:=copyin(where,@data,SizeOf(Pointer)); //data:=where^
            if (Result<>0) then
            begin
             Writeln(StdErr,'reloc_non_plt:','copyin() failed. where=0x',HexStr(where),' [',r_type,']');
             Exit(ENOEXEC);
            end;

            data:=(data + rela^.r_addend + def^.st_value);

            Result:=copyout(@data,where,8); //where^:=data
            if (Result<>0) then
            begin
             Writeln(StdErr,'reloc_non_plt:','copyout() failed. where=0x',HexStr(where),' [',r_type,']');
             Exit(ENOEXEC);
            end;

            if (def<>@dynlibs_info.sym_nops) then
            begin
             set_relo_bits(obj,i);
            end;
           end; //R_X86_64_DTPOFF64

         R_X86_64_TPOFF64:
           begin
            if not allocate_tls_offset(defobj) then
            begin
             Writeln(StdErr,'reloc_non_plt:','No space available for static Thread Local Storage');
             Exit(ENOEXEC);
            end;

            data:=Pointer(def^.st_value - defobj^.tls_offset + rela^.r_addend);

            Result:=copyout(@data,where,SizeOf(Pointer));
            if (Result<>0) then
            begin
             Writeln(StdErr,'reloc_non_plt:','copyout() failed. where=0x',HexStr(where),' [',r_type,']');
             Exit(ENOEXEC);
            end;

            if (def<>@dynlibs_info.sym_nops) then
            begin
             set_relo_bits(obj,i);
            end;
           end; //R_X86_64_TPOFF64

        else;
       end; //case

      end; //R_X86_64_*64

    R_X86_64_PC32,
    R_X86_64_DTPOFF32,
    R_X86_64_TPOFF32: //32
      begin
       Result:=check_addr(obj,where,SizeOf(Integer));
       if (Result<>0) then
       begin
        Writeln(StdErr,'reloc_non_plt:','idx=',i,' where=0x',HexStr(where),' ref=',dynlib_basename(obj^.lib_path));
        Exit;
       end;

       def:=find_symdef(ELF64_R_SYM(rela^.r_info),obj,defobj,flags,@cache[0],where);

       if (def<>nil) then
        case r_type of

         R_X86_64_PC32:
           begin
            data32:=(Integer(QWORD(defobj^.relocbase)) - Integer(QWORD(where))) + Integer(def^.st_value) + Integer(rela^.r_addend);

            if (def<>sym_zero) then
            begin
             data:=Pointer(QWORD(data32));
             //dont check with special callbacks
             //Result:=check_addr(defobj,data,SizeOf(Integer));
             //if (Result<>0) then
             //begin
             // Writeln(StdErr,'reloc_non_plt:','idx=',i,' where32=0x',HexStr(where),' ref=',dynlib_basename(defobj^.lib_path));
             // Exit;
             //end;
            end;

            Result:=relocate_text_or_data_segment(obj,@data32,where,SizeOf(Integer));
            if (Result<>0) then
            begin
             Writeln(StdErr,'reloc_non_plt:','copyout() failed. where32=0x',HexStr(where),' [',r_type,']');
             Exit(ENOEXEC);
            end;

            if (def<>@dynlibs_info.sym_nops) then
            begin
             set_relo_bits(obj,i);
            end;
           end; //R_X86_64_PC32

         R_X86_64_DTPOFF32:
           begin
            Result:=copyin(where,@data,SizeOf(Pointer)); //data:=where^
            if (Result<>0) then
            begin
             Writeln(StdErr,'reloc_non_plt:','copyin() failed. where32=0x',HexStr(where),' [',r_type,']');
             Exit(ENOEXEC);
            end;

            data:=(data + rela^.r_addend + def^.st_value);

            Result:=copyout(@data,where,8); //where^:=data
            if (Result<>0) then
            begin
             Writeln(StdErr,'reloc_non_plt:','copyout() failed. where32=0x',HexStr(where),' [',r_type,']');
             Exit(ENOEXEC);
            end;

            if (def<>@dynlibs_info.sym_nops) then
            begin
             set_relo_bits(obj,i);
            end;
           end; //R_X86_64_DTPOFF32


         R_X86_64_TPOFF32:
           begin
            if not allocate_tls_offset(defobj) then
            begin
             Writeln(StdErr,'reloc_non_plt:','No space available for static Thread Local Storage');
             Exit(ENOEXEC);
            end;

            data32:=Integer(def^.st_value) - Integer(defobj^.tls_offset) + Integer(rela^.r_addend);

            Result:=copyout(@data32,where,SizeOf(Integer));
            if (Result<>0) then
            begin
             Writeln(StdErr,'reloc_non_plt:','copyout() failed. where32=0x',HexStr(where),' [',r_type,']');
             Exit(ENOEXEC);
            end;

            if (def<>@dynlibs_info.sym_nops) then
            begin
             set_relo_bits(obj,i);
            end;
           end; //R_X86_64_TPOFF32

         else;
        end; //case

      end; //R_X86_64_*32

    else
      begin
       Writeln(StdErr,'reloc_non_plt:','Unsupported reloc type=',r_type);
       Exit(ENOEXEC);
      end;
   end; //case

  end;
  //
  _next:
  Inc(rela);
 end;

 Exit(0);
 _move64:

  //Result:=check_addr(defobj,data,SizeOf(Pointer));
  //if (Result<>0) then
  //begin
  // Writeln(StdErr,'reloc_non_plt:','idx=',i,' where=0x',HexStr(where),' ref=',dynlib_basename(defobj^.lib_path));
  // Exit;
  //end;

  Result:=relocate_text_or_data_segment(obj,@data,where,SizeOf(Pointer));
  if (Result<>0) then
  begin
   Writeln(StdErr,'reloc_non_plt:','copyout() failed. where=0x',HexStr(where),' [',r_type,']');
   Exit(ENOEXEC);
  end;

  if (def<>@dynlibs_info.sym_nops) then
  begin
   set_relo_bits(obj,i);
  end;

 goto _next;
end;

function reloc_jmpslot(obj:p_lib_info;i:Integer;cache:p_SymCache;flags:DWORD):Integer;
var
 idofs:Integer;
 entry:p_elf64_rela;

 where:Pointer;
 data:Pointer;

 def:p_elf64_sym;
 defobj:p_lib_info;
begin
 Result:=0;

 if (i<0) or (i>=(obj^.rel_data^.pltrela_size div SizeOf(elf64_rela))) then
 begin
  Exit(1);
 end;

 idofs:=obj^.rel_data^.rela_size div SizeOf(elf64_rela);

 if check_relo_bits(obj,idofs+i) then Exit;

 entry:=obj^.rel_data^.pltrela_addr+i;

 if (ELF64_R_TYPE(entry^.r_info)<>R_X86_64_JUMP_SLOT) then
 begin
  Writeln(StdErr,'reloc_jmpslot:','R_TYPE (',ELF64_R_TYPE(entry^.r_info),') at index ',i,' is bad. (Expected: R_X86_64_JMP_SLOT) in ',dynlib_basename(obj^.lib_path));
  Exit(3);
 end;

 where:=(obj^.relocbase + entry^.r_offset);

 defobj:=nil;
 def:=find_symdef(ELF64_R_SYM(entry^.r_info),obj,defobj,(flags and $200) or SYMLOOK_BASE64,cache,where);

 if (def=nil) then
 begin
  Exit(1);
 end;

 if ((flags and $200)=1) and
    (obj^.rtld_flags.jmpslots_done=0) and
    (defobj^.rtld_flags.jmpslots_done=0) then
 begin
  Exit(5);
 end;

 if (ELF64_ST_VISIBILITY(def^.st_other)=STV_HIDDEN) and
    (defobj<>obj) then
 begin
  Exit(2);
 end;

 data:=defobj^.relocbase + entry^.r_addend + def^.st_value;

 Result:=copyout(@data,where,SizeOf(Pointer));
 if (Result<>0) then
 begin
  Writeln(StdErr,'reloc_jmpslot:','copyout() failed. where=0x',HexStr(where));
  Exit(4);
 end;

 if (def<>@dynlibs_info.sym_nops) then
 begin
  set_relo_bits(obj,idofs+i);
 end;

 if ((flags and $200)=0) then Exit;

 //dl_debug_flags
end;

function reloc_jmpslots(obj:p_lib_info;flags:DWORD):Integer;
var
 cache:array of t_SymCache;

 i,count:Integer;
begin
 Result:=0;

 cache:=nil;
 SetLength(cache,obj^.rel_data^.dynsymcount);

 count:=obj^.rel_data^.pltrela_size div SizeOf(elf64_rela);

 if (obj^.rel_data^.pltrela_addr<>nil) and (count<>0) then
 For i:=0 to count-1 do
  begin
   Result:=reloc_jmpslot(obj,i,@cache[0],flags);
   case Result of
    3:Exit(EINVAL);
    4:Exit(ENOEXEC);
    5:Exit(ENOEXEC);
    else;
   end;
  end;

 Result:=0;
end;

function relocate_one_object(obj:p_lib_info;jmpslots,export_only:Boolean):Integer; public;
begin
 Writeln(' relocate:',dynlib_basename(obj^.lib_path));

 Result:=reloc_non_plt(obj,ord(export_only)*$200);
 if (Result<>0) then
 begin
  Writeln(StdErr,'relocate_one_object:','reloc_non_plt() failed. obj=',dynlib_basename(obj^.lib_path),' rv=',Result);
  Exit;
 end;

 if jmpslots then
 begin
  Result:=reloc_jmpslots(obj,ord(export_only)*$200);
  if (Result<>0) then
  begin
   Writeln(StdErr,'relocate_one_object:','reloc_jmplots() failed. obj=',dynlib_basename(obj^.lib_path),' rv=',Result);
   Exit;
  end;
 end;
end;

function check_copy_relocations(obj:p_lib_info):Integer;
var
 rela:p_elf64_rela;
 i,count:Integer;
begin
 Result:=0;
 if (obj=nil) then Exit;
 if (obj^.rel_data=nil) then Exit;

 rela :=obj^.rel_data^.rela_addr;
 count:=obj^.rel_data^.rela_size div SizeOf(elf64_rela);

 if (count<>0) then
 For i:=0 to count-1 do
 begin
  if (ELF64_R_TYPE(rela^.r_info)=R_X86_64_COPY) then
  begin
   Writeln(StdErr,'check_copy_relocations:','R_X86_64_COPY found in ',dynlib_basename(obj^.lib_path));
   Exit(EINVAL);
  end;
  Inc(rela);
 end;
end;

function dynlib_unlink_non_plt_reloc_each(root,obj:p_lib_info):Integer;
var
 rela:p_elf64_rela;

 where:Pointer;
 data:Pointer;

 data32:Integer;
 r_type:Integer;

 i,count:Integer;
begin
 Result:=0;
 Assert(root<>nil,'Bad dynamic library is specified.');

 rela :=obj^.rel_data^.rela_addr;
 count:=obj^.rel_data^.rela_size div SizeOf(elf64_rela);

 if (rela<>nil) and (count<>0) then
 For i:=0 to count-1 do
 begin
  if check_relo_bits(obj,i) then
  begin
   where:=Pointer(obj^.relocbase)+rela^.r_offset;

   r_type:=ELF64_R_TYPE(rela^.r_info);

   case r_type of

    R_X86_64_NONE:; //ignore

    R_X86_64_COPY:
      if (obj^.rtld_flags.mainprog=0) then
      begin
       Writeln(StdErr,'dynlib_unlink_non_plt_reloc_each:','Unexpected R_X86_64_COPY relocation in dynamic library ',dynlib_basename(obj^.lib_path));
       Exit(-1);
      end; //R_X86_64_COPY

    R_X86_64_64,
    R_X86_64_GLOB_DAT,
    R_X86_64_RELATIVE,
    R_X86_64_TPOFF64:
      begin
       data:=Pointer(QWORD($840000000));

       Result:=relocate_text_or_data_segment(obj,@data,where,SizeOf(Pointer));
       if (Result<>0) then
       begin
        Writeln(StdErr,'dynlib_unlink_non_plt_reloc_each:','copyout() failed. where=0x',HexStr(where),' ref=',dynlib_basename(obj^.lib_path));
        Exit(-1);
       end;

       reset_relo_bits(obj,i);
      end; //64

    R_X86_64_PC32,
    R_X86_64_TPOFF32:
     begin
      data32:=Integer($40000000);

      Result:=relocate_text_or_data_segment(obj,@data32,where,SizeOf(Integer));
      if (Result<>0) then
      begin
       Writeln(StdErr,'dynlib_unlink_non_plt_reloc_each:','copyout() failed. where32=0x',HexStr(where),' ref=',dynlib_basename(obj^.lib_path));
       Exit(-1);
      end;

      reset_relo_bits(obj,i);
     end; //32

    R_X86_64_DTPMOD64,
    R_X86_64_DTPOFF64:
      begin
       data:=nil;

       Result:=copyout(@data,where,SizeOf(Pointer));
       if (Result<>0) then
       begin
        Writeln(StdErr,'dynlib_unlink_non_plt_reloc_each:','copyout() failed. where=0x',HexStr(where),' ref=',dynlib_basename(obj^.lib_path));
        Exit(-1);
       end;

       reset_relo_bits(obj,i);
      end; //64

    R_X86_64_DTPOFF32:
      begin
       data32:=0;

       Result:=copyout(@data32,where,SizeOf(Integer));
       if (Result<>0) then
       begin
        Writeln(StdErr,'dynlib_unlink_non_plt_reloc_each:','copyout() failed. where32=0x',HexStr(where),' ref=',dynlib_basename(obj^.lib_path));
        Exit(-1);
       end;

       reset_relo_bits(obj,i);
      end; //32

    else
      begin
       Writeln(StdErr,'dynlib_unlink_non_plt_reloc_each:','Unsupported reloc type=',r_type);
       Exit(-1);
      end;

   end;
  end; //case
 end;

end;

function dynlib_unlink_plt_reloc_each(root,obj:p_lib_info):Integer;
var
 i,count,idofs:Integer;

 entry:p_elf64_rela;

 def:p_elf64_sym;
 defobj:p_lib_info;

 where:Pointer;
 data:QWORD;

 str:pchar;
begin
 Result:=0;

 count:=obj^.rel_data^.pltrela_size div SizeOf(elf64_rela);
 idofs:=obj^.rel_data^.rela_size    div SizeOf(elf64_rela);

 if (obj^.rel_data^.pltrela_addr<>nil) and (count<>0) then
 For i:=0 to count-1 do
 begin
  if check_relo_bits(obj,idofs+i) then
  begin
   entry:=obj^.rel_data^.pltrela_addr+i;

   if (ELF64_R_TYPE(entry^.r_info)<>R_X86_64_JUMP_SLOT) then
   begin
    Writeln(StdErr,'dynlib_unlink_plt_reloc_each:','R_TYPE (',ELF64_R_TYPE(entry^.r_info),') at index ',i,' is bad. (Expected: R_X86_64_JMP_SLOT) in ',dynlib_basename(obj^.lib_path));
    Exit(-1);
   end;

   defobj:=nil;
   def:=find_symdef(ELF64_R_SYM(entry^.r_info),obj,defobj,SYMLOOK_BASE64,nil,nil);

   if (def=nil) then
   begin
    if (ELF64_R_SYM(entry^.r_info)<=(obj^.rel_data^.symtab_size div SizeOf(elf64_sym))) then
    begin
     def:=nil;
     str:='';
    end else
    begin
     def:=obj^.rel_data^.symtab_addr + ELF64_R_SYM(entry^.r_info);
     str:=obj_get_str(obj,def^.st_name);
    end;

    Writeln(StdErr,'dynlib_unlink_plt_reloc_each:','failed to lookup symbol symp=0x',HexStr(def),' name=',str);
    Exit(-1);
   end else
   if (defobj=root) then
   begin
    where:=Pointer(obj^.relocbase) + entry^.r_offset;

    data:=i or QWORD($effffffe00000000);

    Result:=copyout(@data,where,SizeOf(Pointer));
    if (Result<>0) then
    begin
     Writeln(StdErr,'dynlib_unlink_plt_reloc_each:','copyout() failed. where=0x',HexStr(where),' ref=',dynlib_basename(obj^.lib_path));
     Exit(-1);
    end;

    reset_relo_bits(obj,idofs+i);
   end;

  end;
 end;

end;

function dynlib_unlink_imported_symbols_each(root,obj:p_lib_info):Integer; public;
begin
 Result:=dynlib_unlink_non_plt_reloc_each(root,obj);
 if (Result<>0) then
 begin
  Writeln(StdErr,'dynlib_unlink_imported_symbols_each:','dynlib_unlink_non_plt_reloc_each() fails ',Result);
  Exit;
 end;

 Result:=dynlib_unlink_plt_reloc_each(root,obj);
 if (Result<>0) then
 begin
  Writeln(StdErr,'dynlib_unlink_imported_symbols_each:','dynlib_unlink_plt_reloc_each() fails ',Result);
  Exit;
 end;
end;


end.

