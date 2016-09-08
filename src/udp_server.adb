with Ada.Text_IO;
with Ada.Command_Line;
with Ada.Streams;
with Ada.Unchecked_Conversion;
with Ada.Calendar;
with Interfaces.C;
with System.Multiprocessors.Dispatching_Domains;
with System.Storage_Elements;

with GNAT.Traceback.Symbolic;
with System;

pragma Warnings (Off);
with GNAT.Sockets.Thin;
pragma Warnings (On);

with Base_Udp;
with Output_Data;
with Reliable_Udp;
with Packet_Mgr;
with Queue;

procedure UDP_Server is
   use GNAT.Sockets;

   use type Base_Udp.Header;
   use type Interfaces.Unsigned_64;

   task type Timer is
      entry Start;
      entry Stop;
   end Timer;

   task type Recv_Socket is
      entry Start;
      entry Stop;
   end Recv_Socket;

   pragma Warnings (Off);
   task type Loss_Manager is
      entry Start (Count           : Integer;
                   Data_Address    : System.Address;
                   Last_Address    : System.Address;
                   Number_Missed   : Interfaces.Unsigned_64);
   end Loss_Manager;
   pragma Warnings (On);

   package Sync_Queue is new Queue (System.Address);
   Buffer               : Sync_Queue.Synchronized_Queue;

   Append_Task          : Reliable_Udp.Append_Task;
   Remove_Task          : Reliable_Udp.Remove_Task;
   Ack_Task             : Reliable_Udp.Ack_Task;
   Recv_Socket_Task     : Recv_Socket;
   Log_Task             : Timer;
   Manage_Loss_Task     : Loss_Manager;

   PMH_Buffer_Task      : Packet_Mgr.PMH_Buffer_Addr;
   Release_Buf_Task     : Packet_Mgr.Release_Full_Buf;

   Server               : Socket_Type;
   Address, From        : Sock_Addr_Type;
   Start_Time           : Ada.Calendar.Time;
   Elapsed_Time         : Duration;
   Nb_Packet_Received   : Interfaces.Unsigned_64 := 0;
   Packet_Number        : Reliable_Udp.Pkt_Nb := 0;
   Missed               : Interfaces.Unsigned_64 := 0;
   Last_Nb              : Interfaces.Unsigned_64 := 0;
   Nb_Output            : Natural := 0;
   Log_File             : Ada.Text_IO.File_Type;
   Busy                 : Interfaces.C.int := 50;
   Opt_Return           : Interfaces.C.int;

   function To_Int is
      new Ada.Unchecked_Conversion (GNAT.Sockets.Socket_Type, Interfaces.C.int);

   pragma Warnings (Off);
   procedure Stop_Server;
   pragma Warnings (On);
   procedure Stop_Server is
   begin
      Log_Task.Stop;
      Ack_Task.Stop;
      Remove_Task.Stop;
      Append_Task.Stop;
      PMH_Buffer_Task.Stop;
      Recv_Socket_Task.Stop;

   end Stop_Server;

   procedure Init_Udp;
   procedure Init_Udp is
   begin
      Create_Socket (Server, Family_Inet, Socket_Datagram);
      Set_Socket_Option
         (Server,
         Socket_Level,
         (Reuse_Address, True));
      Set_Socket_Option
         (Server,
         Socket_Level,
         (Receive_Timeout,
         Timeout => 1.0));
      Opt_Return := Thin.C_Setsockopt (S        => To_Int (Server),
                                       Level    => 1,
                                       Optname  => 46,
                                       Optval   => Busy'Address,
                                       Optlen   => 4);
      Ada.Text_IO.Put_Line ("opt return" & Opt_Return'Img);
      Address.Addr := Any_Inet_Addr;
      Address.Port := 50001;
      Bind_Socket (Server, Address);
   end Init_Udp;


   task body Timer is
      use type Ada.Calendar.Time;
   begin
      System.Multiprocessors.Dispatching_Domains.Set_CPU
         (System.Multiprocessors.CPU_Range (14));
      accept Start;
      loop
         select
            accept Stop;
            exit;
         else
            delay 1.0;
            Ada.Text_IO.Put_Line ("Buf len : " & Buffer.Cur_Count'Img);
            Elapsed_Time := Ada.Calendar.Clock - Start_Time;
            Output_Data.Display
               (True,
               Elapsed_Time,
               Packet_Number,
               Missed,
               Nb_Packet_Received,
               Last_Nb,
               Nb_Output);
               Last_Nb := Nb_Packet_Received;
            Nb_Output := Nb_Output + 1;
         end select;
      end loop;
   end Timer;


   task body Loss_Manager is
      Addr        :  System.Address;
      Pos         :  Integer;
      I           :  Integer;
      Data_Addr   :  System.Address;
      Last_Addr   :  System.Address;
      Nb_Missed   :  Interfaces.Unsigned_64;

      use System.Storage_Elements;
   begin
      loop
         accept Start (Count           : Integer;
                       Data_Address    : System.Address;
                       Last_Address    : System.Address;
                       Number_Missed   : Interfaces.Unsigned_64) do
            I           := Count;
            Data_Addr   := Data_Address;
            Last_Addr   := Last_Address;
            Nb_Missed   := Number_Missed;
         end Start;

         for N in I .. I + Integer (Nb_Missed) - 1 loop
            Pos := N;
            if N >= Integer (Base_Udp.Sequence_Size) and I < Integer (Base_Udp.Sequence_Size) then
               Addr  := Data_Addr;
               Pos   := N mod Integer (Base_Udp.Sequence_Size);
            else
               Addr  := Last_Addr;
            end if;

            declare
               Data_Missed  :  Interfaces.Unsigned_32;
               for Data_Missed'Address use Addr + Storage_Offset
                                                   (Pos * Base_Udp.Load_Size);
            begin
               Data_Missed := 16#DEAD_BEEF#;
            end;
         end loop;
      end loop;
   end Loss_Manager;


   task body Recv_Socket is
      Last                 : Ada.Streams.Stream_Element_Offset;
      Watchdog             : Natural := 0;
      pragma Warnings (Off);
      Data_Addr, Last_Addr : System.Address;
      pragma Warnings (On);
      I                    : Integer := Base_Udp.Pkt_Max + 1;
      Nb_Missed            : Interfaces.Unsigned_64;

      use type Interfaces.C.int;
      use type Reliable_Udp.Pkt_Nb;
      use System.Storage_Elements;
   begin
      System.Multiprocessors.Dispatching_Domains.Set_CPU
         (System.Multiprocessors.CPU_Range (16));

      Packet_Mgr.Init_Handle_Array;

      accept Start;
      loop
         select
            accept Stop;
               exit;
         else
            if I > Base_Udp.Pkt_Max then
               PMH_Buffer_Task.New_Buffer_Addr (Buffer_Ptr => Data_Addr);
               I := I mod Integer (Base_Udp.Sequence_Size);
            end if;

            declare
               Data     : Base_Udp.Packet_Stream;

               Header   : Reliable_Udp.Header;

               for Data'Address use Data_Addr + Storage_Offset
                                                   (I * Base_Udp.Load_Size);
               for Header'Address use Data'Address;
            begin
               GNAT.Sockets.Receive_Socket (Server, Data, Last, From);
               Ada.Text_IO.Put_Line ("Received : " & Header.Seq_Nb'Img);

               if Header.Ack then

                  Ada.Text_IO.Put_Line ("___ Save Ack ___");
                  Packet_Mgr.Save_Ack (Header.Seq_Nb, Packet_Number, Data);

                  Remove_Task.Remove (Header.Seq_Nb);
                  I := I - 1;
               else
                  ---  New_Seq := False;
                  Nb_Packet_Received := Nb_Packet_Received + 1;
                  if Nb_Packet_Received = 1 then
                     Start_Time := Ada.Calendar.Clock;
                  end if;

                  if Header.Seq_Nb /= Packet_Number then
                     if Header.Seq_Nb > Packet_Number then
                        Nb_Missed := Interfaces.Unsigned_64
                           (Header.Seq_Nb - Packet_Number);
                        Missed := Missed + Nb_Missed;
                     else
                        --  Doesn't manage disordered packets
                        --  if a packet is received before the previous sent.

                        --  Missed := Missed + Interfaces.Unsigned_64 (Header.Seq_Nb
                        --     + (Base_Udp.Pkt_Max - Packet_Number));

                        Ada.Text_IO.Put_Line ("BAD ORDER");

                        --  New_Seq := True;

                     end if;
                     Packet_Number := Header.Seq_Nb;

                     Last_Addr := Data_Addr;

                     if Interfaces.Unsigned_64 (I) + Nb_Missed >= Base_Udp.Sequence_Size then
                        PMH_Buffer_Task.New_Buffer_Addr (Buffer_Ptr => Data_Addr);
                     end if;

                     --  Memcpy Addr I to I + NB_Missed
                     declare
                        Good_Loc_Index :  constant Integer := (I + Integer (Nb_Missed))
                                             mod Integer (Base_Udp.Sequence_Size);
                        Clear_Bad_Loc  :  Interfaces.Unsigned_32;
                        Good_Location  :  Base_Udp.Packet_Stream;

                        for Good_Location'Address use Data_Addr + Storage_Offset
                                                   (Good_Loc_Index * Base_Udp.Load_Size);
                        for Clear_Bad_Loc'Address use Data'Address;
                     begin
                        Good_Location := Data;
                        Clear_Bad_Loc := 16#DEAD_BEEF#; -- Not necessary if Manage_Loss_Task work
                     end;

                     --  Takes too much time.. Might do a task vector.
                     --  Manage_Loss_Task.Start (I, Data_Addr, Last_Addr, Nb_Missed);

                     I := I + Integer (Nb_Missed);

                     --  Append_Task.Append (Packet_Number,
                     --                      Base_Udp.Header (Header.Seq_Nb),
                     --                      From);
                  end if;

                  if Header.Seq_Nb = Base_Udp.Pkt_Max then
                     Packet_Number := 0;

                     ---  New_Seq := True;
                  else
                     Packet_Number := Packet_Number + 1;
                  end if;

               end if;

               --  Buffer.Append_Wait (Data'Address);
               I := I + 1;
            exception
               when Socket_Error =>
                  Watchdog := Watchdog + 1;
                  Ada.Text_IO.Put_Line ("Socket Error");
                  exit when Watchdog = 10;
            end;
         end select;
      end loop;
   end Recv_Socket;

begin

   Ada.Text_IO.Create (Log_File, Ada.Text_IO.Out_File, "log.csv");
   Ada.Text_IO.Put_Line (Log_File, "Nb_Output;Nb_Received;Packet_Nb;Dropped;Elapsed_Time");
   Ada.Text_IO.Close (Log_File);

   Ada.Text_IO.Create (Log_File, Ada.Text_IO.Out_File, "buffers.log");
   Ada.Text_IO.Close (Log_File);

   if Ada.Command_Line.Argument_Count = 1 then
      System.Multiprocessors.Dispatching_Domains.Set_CPU
         (System.Multiprocessors.CPU_Range (2));
   end if;

   Init_Udp;

   Log_Task.Start;
   Recv_Socket_Task.Start;
   Release_Buf_Task.Start;
   --  Process_Pkt.Start;
   Ack_Task.Start;

   --  delay 40.0;
   --  Stop_Server;

exception
   when E : others =>
      Ada.Text_IO.Put_Line (GNAT.Traceback.Symbolic.Symbolic_Traceback (E));
end UDP_Server;
