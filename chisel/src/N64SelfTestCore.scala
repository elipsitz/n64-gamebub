import chisel3._
import net.gamebub.framework.Core
import net.gamebub.framework.interface._

// Phase 2 Deliverable #2: Self-Contained N64 VR4300 + COP1 FPU + RSP + RDP +
// 48 kHz Audio + 4-Slot Input/Rumble Diagnostic Core (boots embedded MIPS
// self-test ROM in BRAM -> SDRAM without requiring an external .z64 ROM).
class N64SelfTestCore extends Module with Core {
  val mmcmVcoHz = 750_000_000
  val (displayClockMin, displayClockMax) = ClocksV0.getClockDisplayHz(1.0 / 60.0)
  val preferredDiv = 25
  val preferredHz = mmcmVcoHz / preferredDiv
  val displayDivider =
    if (preferredHz >= displayClockMin && preferredHz <= displayClockMax) preferredDiv
    else (mmcmVcoHz.toDouble / displayClockMin).floor.toInt
  val displayClock = mmcmVcoHz / displayDivider

  val io = IO(new Bundle {
    val clocks = new ClocksV0(
      clockSystemHz = 62_500_000,
      clockDisplayHz = displayClock,
      clockSpiHz = 187_500_000,
    )
    val video = new VideoV0(
      videoWidth = 320,
      videoHeight = 240,
      colorDepthR = 6,
      colorDepthG = 6,
      colorDepthB = 6,
      framePeriod = 1.0 / 60.0,
    )
    val audio = new AudioV0()
    val host = new HostV0()
    val input = new InputExtendedV0(numSlots = 4)
    val vibrate = new VibrateV0()
    val cartridge = new CartridgePortV0()
    val sdram = new SdramV0(
      addressWidth = 13,
      dataWidth = 16,
      bankWidth = 2,
      chips = SdramV0.numChips,
    )
    val sram = new SramV0(
      addressWidth = 18,
      dataWidth = 16,
    )
  })

  bindExtModule("n64_gamebub_top", io, Map(
    "DISPLAY_DIVIDER" -> displayDivider,
    "NUM_SDRAM_CHIPS" -> SdramV0.numChips,
    "SELF_TEST_MODE" -> 1,
  ))
}
