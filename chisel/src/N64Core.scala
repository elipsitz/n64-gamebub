import chisel3._
import net.gamebub.framework.Core
import net.gamebub.framework.interface._

class N64Core extends Module with Core {
  // Single MMCME2_ADV VCO = 50 MHz * 15 = 750.000 MHz:
  //   / 12 =  62.500 MHz (N64 RCP & system clock)
  //   /  8 =  93.750 MHz (N64 VR4300 CPU clock, 3:2 synchronous)
  //   /  6 = 125.000 MHz (SDRAM 2x PHY & phase-shifted SDRAM clock)
  //   /  4 = 187.500 MHz (MCU SPI sampling clock, >= 160 MHz)
  //   / 25 =  30.000 MHz (Rev4 ILI9806E display clock, within 25.8..35.0 MHz)
  val mmcmVcoHz = 750_000_000
  val (displayClockMin, displayClockMax) = ClocksV0.getClockDisplayHz(1.0 / 60.0)
  // Prefer 25 (30.0 MHz) when inside bounds, else largest valid divider >= displayClockMin
  val preferredDiv = 25
  val preferredHz = mmcmVcoHz / preferredDiv
  val displayDivider =
    if (preferredHz >= displayClockMin && preferredHz <= displayClockMax) preferredDiv
    else (mmcmVcoHz.toDouble / displayClockMin).floor.toInt
  val displayClock = mmcmVcoHz / displayDivider
  require(
    displayClock >= displayClockMin && displayClock <= displayClockMax,
    s"Display clock $displayClock Hz outside [$displayClockMin, $displayClockMax]"
  )

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
    val sdram = new SdramV0(
      addressWidth = 13,
      dataWidth = 16,
      bankWidth = 2,
      chips = SdramV0.numChips,
      perBitDataTri = true,
    )
    val sram = new SramV0(
      addressWidth = 18,
      dataWidth = 16,
      perBitDataTri = true,
    )
  })

  bindExtModule("n64_gamebub_top", io, Map(
    "DISPLAY_DIVIDER" -> displayDivider,
    "NUM_SDRAM_CHIPS" -> SdramV0.numChips,
  ))
}
