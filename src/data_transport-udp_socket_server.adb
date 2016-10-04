with Ada.Text_IO;
with Ada.Streams;
with Ada.Calendar;
with Ada.Exceptions;
with Interfaces;
with Interfaces.C;
with Ada.Unchecked_Conversion;

pragma Warnings (Off);
with GNAT.Sockets.Thin;
pragma Warnings (On);

with Base_Udp;
with Reliable_Udp;

package body Data_Transport.Udp_Socket_Server is

   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Interfaces.C.int;
   use type Ada.Streams.Stream_Element_Offset;

   use type Reliable_Udp.Pkt_Nb;

   Socket            : GNAT.Sockets.Socket_Type;
   Address           : GNAT.Sockets.Sock_Addr_Type;
   Acquisition       : Boolean := True;
   Packet_Number     : Reliable_Udp.Pkt_Nb := 0;


   procedure Send_Buffer_Data (Buffer_Set : Buffers.Buffer_Consume_Access);


   procedure Send_Packet (Payload : Ada.Streams.Stream_Element_Array);
   procedure Send (Payload : Base_Udp.Packet_Stream);

   procedure Rcv_Ack;

   pragma Warnings (Off);
   procedure Server_HandShake;
   pragma Warnings (On);

   function To_Int is
      new Ada.Unchecked_Conversion (GNAT.Sockets.Socket_Type,
         Interfaces.C.int);


   task body Socket_Server_Task is
   begin
      select
         accept Initialise
           (Network_Interface : String;
            Port : GNAT.Sockets.Port_Type) do

            Address.Addr := GNAT.Sockets.Addresses
                            (GNAT.Sockets.Get_Host_By_Name (Network_Interface));
            Address.Port := Port;
            GNAT.Sockets.Create_Socket
               (Socket,
                GNAT.Sockets.Family_Inet,
                GNAT.Sockets.Socket_Datagram);
         end Initialise;
      or
         terminate;
      end select;
      loop
         select
            accept Connect;
            exit;
         or
            terminate;
         end select;
      end loop;

      <<HandShake>>
      Server_HandShake;
      Acquisition := True;
      delay 0.0001;
      Ada.Text_IO.Put_Line ("Consumer ready, start sending packets...");

      loop
         select
            accept Disconnect;
               GNAT.Sockets.Close_Socket (Socket);
               exit;
         else
            if Acquisition then
               Rcv_Ack;
               select
                  Buffer_Set.Block_Full;
                  Send_Buffer_Data (Buffer_Set);
               else
                  null;
               end select;
            else
               declare
                  Start_Time  : constant Ada.Calendar.Time := Ada.Calendar.Clock;
                  Cur_Time    : Ada.Calendar.Time;
                  use type Ada.Calendar.Time;
               begin
                  loop
                     Rcv_Ack; -- Give server 2s to be sure it has all packets

                     Cur_Time := Ada.Calendar.Clock;
                     if Cur_Time - Start_Time > 2.0 then
                        goto HandShake;
                     end if;
                  end loop;
               end;
            end if;
         end select;
      end loop;

   exception
      when E : others =>
         Ada.Text_IO.Put_Line (ASCII.ESC & "[31m" & "Exception : " &
            Ada.Exceptions.Exception_Name (E)
            & ASCII.LF & ASCII.ESC & "[33m"
            & Ada.Exceptions.Exception_Message (E)
            & ASCII.ESC & "[0m");
   end Socket_Server_Task;


   ------------------------
   --  Server_HandShake  --
   ------------------------

   procedure Server_HandShake is
      Send_Data, Recv_Data : Base_Udp.Packet_Stream;
      Send_Head, Recv_Head : Reliable_Udp.Header;

      for Send_Head'Address use Send_Data'Address;
      for Recv_Head'Address use Recv_Data'Address;
   begin
      Send_Head.Seq_Nb := 0;
      loop
         Send (Send_Data);
         delay 0.2;
         exit when GNAT.Sockets.Thin.C_Recv
               (To_Int (Socket),
                Recv_Data (Recv_Data'First)'Address,
                Recv_Data'Length,
                64) /= -1
               and Recv_Head.Ack = False
               and (Recv_Head.Seq_Nb = Send_Head.Seq_Nb);
               --  Should rename Seq_Nb by Msg in this case.
      end loop;
   end Server_HandShake;

   ------------------------
   --  Send_Buffer_Data  --
   ------------------------

   procedure Send_Buffer_Data (Buffer_Set : Buffers.Buffer_Consume_Access) is
   begin
      declare
         Buffer_Handle : Buffers.Buffer_Handle_Type;
      begin
         Buffer_Set.Get_Full_Buffer (Buffer_Handle);
         declare
            Data_Size : constant Ada.Streams.Stream_Element_Offset :=
              Ada.Streams.Stream_Element_Offset
              (Buffers.Get_Used_Bytes (Buffer_Handle));
            Data : Ada.Streams.Stream_Element_Array (1 .. Data_Size);
            for Data'Address use Buffers.Get_Address (Buffer_Handle);
         begin
            Send_Packet (Data);
         exception
            when E : others =>
               Ada.Text_IO.Put_Line
                 ("data transmit unattended exception : " &
                    Ada.Exceptions.Exception_Name (E) & "," &
                    Ada.Exceptions.Exception_Message (E));
               raise;
         end;
         Buffer_Set.Release_Full_Buffer (Buffer_Handle);
      end;

   end Send_Buffer_Data;


   -------------------
   --  Send_Packet  --
   -------------------

   procedure Send_Packet (Payload : Ada.Streams.Stream_Element_Array) is
      use type Ada.Streams.Stream_Element_Array;

      First : Ada.Streams.Stream_Element_Offset := Payload'First;
      Index : Ada.Streams.Stream_Element_Offset := First - 1;
      Last  : Ada.Streams.Stream_Element_Offset;
   begin
      loop
         Rcv_Ack;
         declare
            Data     : Ada.Streams.Stream_Element_Array (1 .. 2);
            Header   : Reliable_Udp.Header := (Ack => False,
                                                Seq_Nb => Packet_Number);
            for Header'Address use Data'Address;
         begin
            Last := First + (Base_Udp.Load_Size - Base_Udp.Header_Size) - 1;
            GNAT.Sockets.Send_Socket (Socket, Data & Payload
               (First ..  (if Last > Payload'Last then
                              Payload'Last
                           else
                              Last)),
               Index, Address);
         end;
         Packet_Number := Packet_Number + 1;
         Ada.Text_IO.Put_Line ("Index" & Index'Img);
         Ada.Text_IO.Put_Line ("First" & First'Img);
         First := Last + 1;
         exit when First > Payload'Last;
      end loop;
   end Send_Packet;

   ------------
   --  Send  --
   ------------

   procedure Send (Payload : Base_Udp.Packet_Stream) is
      Offset   : Ada.Streams.Stream_Element_Offset;
      Data     : Ada.Streams.Stream_Element_Array (1 .. Base_Udp.Load_Size);

      for Data'Address use Payload'Address;
      pragma Unreferenced (Offset);
   begin
      GNAT.Sockets.Send_Socket (Socket, Data, Offset, Address);
   end Send;


   ---------------
   --  Rcv_Ack  --
   ---------------

   procedure Rcv_Ack is
      Payload  : Base_Udp.Packet_Stream;
      Head     : Reliable_Udp.Header;
      Ack      : array (1 .. 64) of Interfaces.Unsigned_8 := (others => 0);
      Data     : Ada.Streams.Stream_Element_Array (1 .. 64);
      Res      : Interfaces.C.int;

      for Ack'Address use Payload'Address;
      for Data'Address use Ack'Address;
      for Head'Address use Ack'Address;
   begin
      loop
         Res := GNAT.Sockets.Thin.C_Recv
            (To_Int (Socket), Data (Data'First)'Address, Data'Length, 64);

         exit when Res = -1;

         if Head.Ack = False then
            if Head.Seq_Nb = 2 then
               Ada.Text_IO.Put_Line ("...Server asked to STOP ACQUISITION...");
               Ada.Text_IO.Put_Line ("Client stopped sending data.");
               Acquisition := False;
               return;
            elsif Head.Seq_Nb = 1 then
               Ada.Text_IO.Put_Line ("...Server asked to START ACQUISITION...");
               Acquisition := True;
               return;
            end if;
         else
            Head.Ack := True;
            Send (Payload);
         end if;
      end loop;
   end Rcv_Ack;

end Data_Transport.Udp_Socket_Server;
